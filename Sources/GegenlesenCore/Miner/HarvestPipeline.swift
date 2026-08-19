import Foundation

public struct HarvestPipeline: Sendable {
    public var store: Store
    public var skipAgent: Bool
    public var miner: (any MinerRunning)?
    public var suggestionJudge: (any SuggestionJudging)?
    public var model: String
    public var embedder: (any EmbeddingClient)?
    public var maxChunks: Int

    public init(
        store: Store,
        skipAgent: Bool,
        miner: (any MinerRunning)? = nil,
        suggestionJudge: (any SuggestionJudging)? = nil,
        model: String,
        embedder: (any EmbeddingClient)? = nil,
        maxChunks: Int = 20_000
    ) {
        self.store = store
        self.skipAgent = skipAgent
        self.miner = miner
        self.suggestionJudge = suggestionJudge
        self.model = model
        self.embedder = embedder
        self.maxChunks = maxChunks
    }

    public func run(jobID: JobID) async throws {
        if let existing = try await store.job(id: jobID), existing.status.isTerminal {
            return
        }
        try await store.appendEvent(jobID: jobID, level: .info, message: "harvest_dequeued")
        _ = try? await store.apply(jobID: jobID, event: .dequeued)

        do {
            let workspaceURL = store.blobs.workspaceURL(jobID: jobID.rawValue)
            let archive = store.blobs.archiveURL(jobID: jobID.rawValue)
            try ArchiveUnpacker().unpack(archive: archive, into: workspaceURL)
            try await store.appendEvent(jobID: jobID, level: .info, message: "unpacked")
            if let job = try await store.job(id: jobID), job.repository == nil,
               let detected = RepositoryName.detect(in: workspaceURL) {
                try await store.updateJobRepository(id: jobID, repository: detected)
            }

            let scan = HarvestScanner.scan(root: workspaceURL)
            try HarvestScanner.write(scan, workspace: workspaceURL)
            try Self.prompt(scan: scan).write(
                to: workspaceURL.appendingPathComponent(".gegenlesen/prompt.md"),
                atomically: true,
                encoding: .utf8
            )
            try await dismissUnvettedHarvest(now: Date())

            var bundle: HarvestBundle
            if skipAgent || miner == nil {
                bundle = hostOnly(scan: scan)
            } else {
                let result = await miner!.runMiner(
                    jobID: jobID,
                    workspace: Workspace(root: workspaceURL),
                    model: model,
                    isCancelled: { [store, jobID] in
                        guard let job = try? await store.job(id: jobID) else { return true }
                        return job.status.isTerminal
                    }
                )
                try await store.updateJobContainers(jobID: jobID, containerName: result.containerName)
                let harvestURL = workspaceURL.appendingPathComponent(".gegenlesen/harvest.json")
                if let data = try? Data(contentsOf: harvestURL),
                   let parsed = try? HarvestFile.parse(data) {
                    bundle = parsed
                } else {
                    if result.failed {
                        try await store.appendEvent(
                            jobID: jobID,
                            level: .warning,
                            message: result.errorMessage ?? "miner_failed"
                        )
                    }
                    bundle = hostOnly(scan: scan)
                }
            }

            bundle = HarvestFile.cap(HarvestFile.dropUncited(bundle))
            let kept = try await judge(bundle, workspace: workspaceURL, jobID: jobID)
            let now = Date()
            let counts = try await persist(kept, jobID: jobID, now: now)

            let indexer = ArchitectureIndexJob(
                store: store,
                embedder: embedder,
                maxChunks: maxChunks,
                skipAgent: skipAgent,
                miner: miner,
                model: model
            )
            _ = try? await indexer.run(workspace: Workspace(root: workspaceURL), jobID: jobID)

            try await store.appendEvent(
                jobID: jobID,
                level: .info,
                message: "harvest_done",
                payloadJSON: #"{"rules":\#(counts.rules),"notes":\#(counts.notes)}"#
            )
            _ = try await store.finishJob(id: jobID, status: .succeeded)
        } catch {
            _ = try await store.finishJob(
                id: jobID,
                status: .failed,
                errorMessage: String(describing: error)
            )
            try? await store.appendEvent(jobID: jobID, level: .error, message: String(describing: error))
        }
    }

    /// Persist an already-written harvest.json without remine or re-judge.
    @discardableResult
    public func ingestExistingHarvest(jobID: JobID) async throws -> (rules: Int, notes: Int) {
        let workspaceURL = store.blobs.workspaceURL(jobID: jobID.rawValue)
        let harvestURL = workspaceURL.appendingPathComponent(".gegenlesen/harvest.json")
        guard let data = try? Data(contentsOf: harvestURL),
              let parsed = try? HarvestFile.parse(data)
        else {
            throw HarvestIngestError.missingHarvestFile
        }
        let bundle = HarvestFile.cap(HarvestFile.dropUncited(parsed))
        let counts = try await persist(bundle, jobID: jobID, now: Date())
        try await store.appendEvent(
            jobID: jobID,
            level: .info,
            message: "harvest_ingested",
            payloadJSON: #"{"rules":\#(counts.rules),"notes":\#(counts.notes)}"#
        )
        return counts
    }

    private func hostOnly(scan: HarvestScan) -> HarvestBundle {
        let notes = scan.prose.prefix(HarvestFile.maxNotes).map { item in
            HarvestNoteDraft(
                title: "From \(item.path)",
                body: String(item.excerpt.prefix(1_200)),
                evidence: [RuleExample(path: item.path, excerpt: String(item.excerpt.prefix(240)))]
            )
        }
        return HarvestBundle(rules: [], notes: Array(notes))
    }

    private func judge(
        _ bundle: HarvestBundle,
        workspace: URL,
        jobID: JobID
    ) async throws -> HarvestBundle {
        var candidates: [SuggestionCandidate] = []
        for (index, rule) in bundle.rules.enumerated() {
            candidates.append(
                SuggestionCandidate(
                    id: "sug_rule_\(index)",
                    kind: .rule,
                    title: rule.title,
                    body: rule.body.isEmpty ? rule.title : rule.body
                )
            )
        }
        for (index, note) in bundle.notes.enumerated() {
            candidates.append(
                SuggestionCandidate(
                    id: "sug_note_\(index)",
                    kind: .context,
                    title: note.title,
                    body: note.body
                )
            )
        }
        var kept = candidates
        if !skipAgent, let suggestionJudge, !candidates.isEmpty, let job = try await store.job(id: jobID) {
            try SuggestionJudge.writeInput(
                candidates,
                workspace: workspace,
                prompt: SuggestionJudge.harvestPrompt
            )
            let judged = await suggestionJudge.runSuggestionJudge(
                job: job,
                workspace: Workspace(root: workspace)
            )
            let failed = judged.outcome == .failed
            kept = SuggestionJudge.apply(
                outcome: judged.outcome,
                candidates: candidates,
                fallbackIDs: Set(candidates.map(\.id))
            )
            try await store.appendEvent(
                jobID: jobID,
                level: failed ? .warning : .info,
                message: failed ? "suggestion_judge_failed" : "suggestion_judged",
                payloadJSON: #"{"candidates":\#(candidates.count),"kept":\#(kept.count)}"#
            )
        }
        let byID = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0) })
        var rules: [MinedRuleDraft] = []
        for (index, draft) in bundle.rules.enumerated() {
            guard let keptItem = byID["sug_rule_\(index)"] else { continue }
            var next = draft
            next.title = keptItem.title
            next.body = keptItem.body
            if case .semantic(_, let shots) = next.payload {
                next.payload = .semantic(instruction: keptItem.body, fewShots: shots)
            }
            rules.append(next)
        }
        var notes: [HarvestNoteDraft] = []
        for (index, draft) in bundle.notes.enumerated() {
            guard let keptItem = byID["sug_note_\(index)"] else { continue }
            notes.append(HarvestNoteDraft(title: keptItem.title, body: keptItem.body, evidence: draft.evidence))
        }
        return HarvestFile.cap(HarvestBundle(rules: rules, notes: notes))
    }

    private func persist(
        _ bundle: HarvestBundle,
        jobID: JobID,
        now: Date
    ) async throws -> (rules: Int, notes: Int) {
        let repository = try await store.job(id: jobID)?.repository
        var ruleCount = 0
        for draft in bundle.rules {
            let rule = Rule(
                id: RuleID.slug(from: "harvest-\(draft.title)"),
                title: draft.title,
                severity: draft.severity,
                kind: draft.kind,
                enabled: false,
                provenance: .harvest,
                languages: draft.languages.isEmpty ? ["*"] : draft.languages,
                pathGlobs: draft.pathGlobs,
                repository: repository,
                payload: draft.payload,
                examples: draft.examples,
                sourcePRRefs: ["harvest"],
                body: draft.body,
                createdAt: now,
                updatedAt: now
            )
            let outcome = try await MinerDedup.upsert(rule, into: store, now: now)
            let ruleID: RuleID
            switch outcome {
            case .inserted(let id): ruleID = id
            case .attached(let id): ruleID = id
            }
            try await store.insertLearning(
                Learning(
                    jobID: jobID,
                    kind: .rule,
                    title: draft.title,
                    body: draft.body,
                    payloadJSON: Self.json([
                        "source": "harvest",
                        "rule_id": ruleID.rawValue,
                    ]),
                    createdAt: now
                )
            )
            ruleCount += 1
        }
        var noteCount = 0
        for note in bundle.notes {
            try await store.insertLearning(
                Learning(
                    jobID: jobID,
                    kind: .context,
                    title: note.title,
                    body: note.body,
                    payloadJSON: Self.json(["source": "harvest"]),
                    createdAt: now
                )
            )
            noteCount += 1
        }
        return (ruleCount, noteCount)
    }

    private func dismissUnvettedHarvest(now: Date) async throws {
        let pending = try await store.listLearnings(status: .pending)
        for item in pending {
            guard item.payloadJSON?.contains("\"source\":\"harvest\"") == true else { continue }
            var next = item
            next.status = .dismissed
            next.resolvedAt = now
            try await store.updateLearning(next)
        }
    }

    private static func json(_ object: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    static func prompt(scan: HarvestScan) -> String {
        let tools = scan.suppressions.map { "- \($0.tool) (\($0.path))" }.joined(separator: "\n")
        let prose = scan.prose.map { "- \($0.path)" }.joined(separator: "\n")
        return """
        # gegenlesen harvest

        Write `.gegenlesen/harvest.json` in one Write. Do not use TodoWrite.
        Do not edit source. Read harvest-scan.json, README, CONTRIBUTING, then stop.

        Tools already enforce (do not restate):
        \(tools.isEmpty ? "- none found" : tools)

        Prose files:
        \(prose.isEmpty ? "- none found" : prose)

        Prefer conventions seen in two files. Each item needs evidence
        {path, excerpt}. Drop taste and README wishes with no matching code.

        JSON only:
        {"rules":[{"title","severity","kind":"semantic","languages":["*"],"path_globs":["**/*"],"instruction","body","evidence":[{"path","excerpt"}]}],"notes":[{"title","body","evidence":[{"path","excerpt"}]}]}

        At most 8 rules and 5 notes.
        """
    }
}
