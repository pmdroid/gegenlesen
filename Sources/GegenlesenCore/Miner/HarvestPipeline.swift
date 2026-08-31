import Foundation

public struct HarvestPipeline: Sendable {
    public var store: Store
    public var skipAgent: Bool
    public var miner: (any MinerRunning)?
    public var suggestionJudge: (any SuggestionJudging)?
    public var engine: String
    public var model: String
    public var embedder: (any EmbeddingClient)?
    public var maxChunks: Int

    public init(
        store: Store,
        skipAgent: Bool,
        miner: (any MinerRunning)? = nil,
        suggestionJudge: (any SuggestionJudging)? = nil,
        engine: String = AgentEngineID.opencode,
        model: String,
        embedder: (any EmbeddingClient)? = nil,
        maxChunks: Int = 20_000
    ) {
        self.store = store
        self.skipAgent = skipAgent
        self.miner = miner
        self.suggestionJudge = suggestionJudge
        self.engine = engine
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
               let detected = RepositoryName.detectPackedOrRemote(in: workspaceURL) {
                try await store.updateJobRepository(id: jobID, repository: detected)
            }

            let scan = HarvestScanner.scan(root: workspaceURL)
            try HarvestScanner.write(scan, workspace: workspaceURL)
            try Self.prompt(scan: scan).write(
                to: workspaceURL.appendingPathComponent(".gegenlesen/prompt.md"),
                atomically: true,
                encoding: .utf8
            )

            var bundle: HarvestBundle
            if skipAgent || miner == nil {
                bundle = hostOnly(scan: scan)
            } else {
                try await store.appendEvent(jobID: jobID, level: .info, message: "harvest_mining")
                let result = await miner!.runMiner(
                    jobID: jobID,
                    workspace: Workspace(root: workspaceURL),
                    engine: engine,
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
                    let message = result.errorMessage ?? "miner_failed"
                    try await store.appendEvent(jobID: jobID, level: .error, message: message)
                    try await failHarvest(jobID: jobID, message: message)
                    return
                }
            }

            bundle = HarvestFile.cap(HarvestFile.dropUncited(bundle))
            try await store.appendEvent(jobID: jobID, level: .info, message: "harvest_judging")
            let judged = try await judge(bundle, workspace: workspaceURL, jobID: jobID)
            if let job = try await store.job(id: jobID), job.status.isTerminal {
                return
            }
            let now = Date()
            if judged.failed {
                let quarantined = try await quarantine(bundle, jobID: jobID, now: now)
                try await store.appendEvent(
                    jobID: jobID,
                    level: .error,
                    message: "harvest_judge_failed",
                    payloadJSON: Self.jsonObject([
                        "quarantined": quarantined,
                        "judged": false,
                    ])
                )
                try await failHarvest(jobID: jobID, message: "harvest_judge_failed")
                return
            }
            try await dismissHarvest(status: .pending, now: now)
            let counts = try await persist(judged.bundle, jobID: jobID, now: now, judged: judged.judged)
            // A later judged harvest is the retry. Leftover timeout drafts
            // must not keep filling Ledger after this pass succeeds.
            try await dismissHarvest(status: .needsRejudge, now: now)

            try await store.appendEvent(
                jobID: jobID,
                level: .info,
                message: "harvest_done",
                payloadJSON: Self.jsonObject([
                    "rules": counts.rules,
                    "notes": counts.notes,
                    "skipped": counts.skipped,
                    "judged": judged.judged,
                ])
            )
            _ = try await store.finishJob(id: jobID, status: .succeeded)

            // File-walk embeddings on a large harvest tree can occupy the only
            // job worker for hours. Harvest already persisted learnings; the
            // next review indexes the tree. Do not block harvest on it.
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
        let counts = try await persist(bundle, jobID: jobID, now: Date(), judged: false)
        try await store.appendEvent(
            jobID: jobID,
            level: .info,
            message: "harvest_ingested",
            payloadJSON: Self.jsonObject([
                "rules": counts.rules,
                "notes": counts.notes,
                "skipped": counts.skipped,
            ])
        )
        return (counts.rules, counts.notes)
    }

    private func hostOnly(scan: HarvestScan) -> HarvestBundle {
        let notes = scan.prose.prefix(HarvestFile.maxNotes).map { item in
            HarvestNoteDraft(
                title: "From \(item.path)",
                body: String(item.excerpt.prefix(HarvestFile.maxNoteBodyChars)),
                evidence: [RuleExample(path: item.path, excerpt: String(item.excerpt.prefix(240)))]
            )
        }
        return HarvestBundle(rules: [], notes: Array(notes))
    }

    private func judge(
        _ bundle: HarvestBundle,
        workspace: URL,
        jobID: JobID
    ) async throws -> (bundle: HarvestBundle, judged: Bool, failed: Bool) {
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
        var didJudge = false
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
            didJudge = !judged.failed
            // Harvest has no host endorsement. Judge failure must not keep drafts.
            kept = judged.failed
                ? []
                : SuggestionJudge.apply(
                    outcome: judged.outcome,
                    candidates: candidates,
                    fallbackIDs: []
                )
            try await store.appendEvent(
                jobID: jobID,
                level: judged.failed ? .warning : .info,
                message: judged.failed ? "suggestion_judge_failed" : "suggestion_judged",
                payloadJSON: SuggestionJudge.eventPayload(
                    candidates: candidates.count,
                    kept: kept.count,
                    result: judged
                )
            )
            if judged.failed {
                return (HarvestBundle(), false, true)
            }
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
        return (HarvestFile.cap(HarvestBundle(rules: rules, notes: notes)), didJudge, false)
    }

    private func failHarvest(jobID: JobID, message: String) async throws {
        _ = try await store.finishJob(id: jobID, status: .failed, errorMessage: message)
    }

    private func quarantine(
        _ bundle: HarvestBundle,
        jobID: JobID,
        now: Date
    ) async throws -> Int {
        var count = 0
        for draft in bundle.rules {
            if try await promoteNeedsRejudge(
                kind: .rule,
                title: draft.title,
                body: draft.body,
                extra: ["source": "harvest", "judged": false]
            ) {
                count += 1
                continue
            }
            if try await LearningDedup.alreadySettled(store: store, kind: .rule, title: draft.title) {
                continue
            }
            try await store.insertLearning(
                Learning(
                    jobID: jobID,
                    kind: .rule,
                    status: .needsRejudge,
                    title: draft.title,
                    body: draft.body,
                    payloadJSON: Self.jsonObject([
                        "source": "harvest",
                        "judged": false,
                    ]),
                    createdAt: now
                )
            )
            count += 1
        }
        for note in bundle.notes {
            if try await promoteNeedsRejudge(
                kind: .context,
                title: note.title,
                body: note.body,
                extra: ["source": "harvest", "judged": false]
            ) {
                count += 1
                continue
            }
            if try await LearningDedup.alreadySettled(store: store, kind: .context, title: note.title) {
                continue
            }
            try await store.insertLearning(
                Learning(
                    jobID: jobID,
                    kind: .context,
                    status: .needsRejudge,
                    title: note.title,
                    body: note.body,
                    payloadJSON: Self.jsonObject([
                        "source": "harvest",
                        "judged": false,
                    ]),
                    createdAt: now
                )
            )
            count += 1
        }
        return count
    }

    private func promoteNeedsRejudge(
        kind: LearningKind,
        title: String,
        body: String,
        extra: [String: Any],
        to status: LearningStatus = .needsRejudge
    ) async throws -> Bool {
        let items = try await store.listLearnings(status: .needsRejudge, kind: kind)
        guard var existing = items.first(where: {
            Normalize.titleKey($0.title) == Normalize.titleKey(title)
        }) else {
            return false
        }
        existing.status = status
        existing.title = title
        existing.body = body
        if status == .pending {
            existing.resolvedAt = nil
        }
        existing.mergePayload(extra)
        try await store.updateLearning(existing)
        return true
    }

    private func persist(
        _ bundle: HarvestBundle,
        jobID: JobID,
        now: Date,
        judged: Bool
    ) async throws -> (rules: Int, notes: Int, skipped: Int) {
        let repository = try await store.job(id: jobID)?.repository
        var ruleCount = 0
        var skipped = 0
        for draft in bundle.rules {
            if try await LearningDedup.alreadySettled(
                store: store,
                kind: .rule,
                title: draft.title
            ) {
                skipped += 1
                continue
            }
            if let existing = try await store.ftsTop1Rule(matching: draft.title),
               existing.deletedAt == nil,
               existing.provenance == .handwritten || existing.enabled
            {
                skipped += 1
                continue
            }
            let rule = harvestRule(from: draft, repository: repository, now: now)
            let outcome = try await MinerDedup.upsert(rule, into: store, now: now)
            let ruleID: RuleID
            switch outcome {
            case .inserted(let id): ruleID = id
            case .attached(let id): ruleID = id
            }
            let payload: [String: Any] = [
                "source": "harvest",
                "rule_id": ruleID.rawValue,
                "judged": judged,
            ]
            if try await promoteNeedsRejudge(
                kind: .rule,
                title: draft.title,
                body: draft.body,
                extra: payload,
                to: .pending
            ) {
                ruleCount += 1
                continue
            }
            try await store.insertLearning(
                Learning(
                    jobID: jobID,
                    kind: .rule,
                    title: draft.title,
                    body: draft.body,
                    payloadJSON: Self.jsonObject(payload),
                    createdAt: now
                )
            )
            ruleCount += 1
        }
        var noteCount = 0
        for note in bundle.notes {
            if try await promoteNeedsRejudge(
                kind: .context,
                title: note.title,
                body: note.body,
                extra: [
                    "source": "harvest",
                    "judged": judged,
                ],
                to: .pending
            ) {
                noteCount += 1
                continue
            }
            if try await LearningDedup.alreadySettled(
                store: store,
                kind: .context,
                title: note.title
            ) {
                skipped += 1
                continue
            }
            try await store.insertLearning(
                Learning(
                    jobID: jobID,
                    kind: .context,
                    title: note.title,
                    body: note.body,
                    payloadJSON: Self.jsonObject([
                        "source": "harvest",
                        "judged": judged,
                    ]),
                    createdAt: now
                )
            )
            noteCount += 1
        }
        return (ruleCount, noteCount, skipped)
    }

    private func harvestRule(
        from draft: MinedRuleDraft,
        repository: String?,
        now: Date
    ) -> Rule {
        Rule(
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
    }

    private func dismissHarvest(status: LearningStatus, now: Date) async throws {
        let items = try await store.listLearnings(status: status)
        for item in items {
            guard item.payloadJSON?.contains("\"source\":\"harvest\"") == true else { continue }
            var next = item
            next.status = .dismissed
            next.resolvedAt = now
            try await store.updateLearning(next)
        }
    }

    private static func jsonObject(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
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
        Do not paste whole README.md or docs/*.md files into notes.
        Note body at most \(HarvestFile.maxNoteBodyChars) characters.

        JSON only:
        {"rules":[{"title","severity","kind":"semantic","languages":["*"],"path_globs":["**/*"],"instruction","body","evidence":[{"path","excerpt"}]}],"notes":[{"title","body","evidence":[{"path","excerpt"}]}]}

        At most 8 rules and 5 notes.
        """
    }
}
