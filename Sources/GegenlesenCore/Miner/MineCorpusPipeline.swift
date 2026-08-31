import Foundation

public struct MineCorpusPipeline: Sendable {
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

    public func run(jobID: JobID, spec: MineJobSpec) async throws {
        if let existing = try await store.job(id: jobID), existing.status.isTerminal {
            return
        }
        try await store.appendEvent(jobID: jobID, level: .info, message: "mine_dequeued")
        _ = try? await store.apply(jobID: jobID, event: .dequeued)

        do {
            let items = try await loadItems(spec)
            let workspaceURL = store.blobs.workspaceURL(jobID: jobID.rawValue)
            try await stage(items: items, spec: spec, workspace: workspaceURL)

            var drafts: [MinedRuleDraft]
            if skipAgent || miner == nil {
                drafts = try await deterministicDrafts(items: items, spec: spec)
            } else {
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
                if result.failed {
                    _ = try await store.finishJob(
                        id: jobID,
                        status: .failed,
                        errorMessage: result.errorMessage ?? "miner_failed"
                    )
                    try await store.appendEvent(jobID: jobID, level: .error, message: result.errorMessage ?? "miner_failed")
                    return
                }
                let minedURL = workspaceURL.appendingPathComponent(".gegenlesen/mined-rules.json")
                if let data = try? Data(contentsOf: minedURL), !data.isEmpty {
                    if let parsed = try? MinedRulesFile.parse(data) {
                        drafts = parsed
                    } else {
                        drafts = try await deterministicDrafts(items: items, spec: spec)
                    }
                } else {
                    drafts = try await deterministicDrafts(items: items, spec: spec)
                }
            }

            let filtered = try await filterDrafts(drafts, spec: spec)
            let now = Date()
            let counts = try await fillInbox(
                items: items,
                spec: spec,
                drafts: filtered,
                workspace: workspaceURL,
                jobID: jobID,
                now: now
            )

            try await store.markCorpusMined(ids: items.map(\.id), at: now)
            try await store.appendEvent(
                jobID: jobID,
                level: .info,
                message: "mine_done",
                payloadJSON: #"{"inserted":\#(counts.inserted),"attached":\#(counts.attached)}"#
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

    private func loadItems(_ spec: MineJobSpec) async throws -> [CorpusItem] {
        guard spec.source == .corpus else { return [] }
        let all = try await store.listCorpusItems()
        guard let requested = spec.itemIDs, !requested.isEmpty else {
            return all
        }
        let wanted = Set(requested)
        return all.filter { wanted.contains($0.id) }
    }

    private func stage(items: [CorpusItem], spec: MineJobSpec, workspace: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: workspace.appendingPathComponent(".gegenlesen", isDirectory: true),
            withIntermediateDirectories: true
        )
        for item in items {
            let dest = workspace.appendingPathComponent("corpus/\(item.id)", isDirectory: true)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let patch = store.blobs.corpusPatchURL(itemID: item.id)
            let json = store.blobs.corpusJSONURL(itemID: item.id)
            if fm.fileExists(atPath: patch.path) {
                try? fm.copyItem(at: patch, to: dest.appendingPathComponent("item.patch"))
            }
            if fm.fileExists(atPath: json.path) {
                try? fm.copyItem(at: json, to: dest.appendingPathComponent("item.json"))
            }
        }
        if spec.source == .job, let sourceID = spec.sourceJobID {
            let dest = workspace.appendingPathComponent("job", isDirectory: true)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let patch = store.blobs.patchURL(jobID: sourceID.rawValue)
            if fm.fileExists(atPath: patch.path) {
                try? fm.copyItem(at: patch, to: dest.appendingPathComponent("change.patch"))
            }
            let findings = try await store.findings(jobID: sourceID)
            let findingsData = Self.encodeFindings(findings)
            try findingsData.write(to: dest.appendingPathComponent("findings.json"), options: .atomic)
            try findingsData.write(
                to: workspace.appendingPathComponent(".gegenlesen/findings.json"),
                options: .atomic
            )
            let feedback = try await store.findingFeedback(jobID: sourceID)
            let sourceJob = try await store.job(id: sourceID)
            if let object = SuggestionFilter.stagedFeedbackJSON(
                findingFeedback: feedback,
                risk: sourceJob?.risk
            ),
               let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                try data.write(to: dest.appendingPathComponent("feedback.json"), options: .atomic)
            }
        }
        let prompt = """
            Extract a small set of reusable house rules from this workspace.
            Write only `.gegenlesen/mined-rules.json` as `{"rules":[...]}`.
            Each rule must include title, path_globs, and a semantic instruction.
            Set enabled to false. Do not edit other files.
            Write for FUTURE changes: generic, not this PR's file names, tickets,
            or one function. Prefer operator thumbs-up and should_be_rule in
            job/feedback.json. Do not turn every finding into a rule.
            job/feedback.json may include merge_intent from the operator's
            "would you have merged this unread?" label.
            would_merge=true is a positive exemplar for this class of diff.
            would_merge=false means kept errors on this job are mine-worthy
            even without thumbs. weight=highest (auto_approve then the
            operator said no) is the strongest would-not exemplar.
            Never drop an individual finding because of the job-level label.
            For job sources, read job/change.patch, job/findings.json, and job/feedback.json.
            """
        try prompt.write(
            to: workspace.appendingPathComponent(".gegenlesen/prompt.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func deterministicDrafts(items: [CorpusItem], spec: MineJobSpec) async throws -> [MinedRuleDraft] {
        if spec.source == .job, let sourceID = spec.sourceJobID {
            let findings = try await store.findings(jobID: sourceID)
            if findings.isEmpty {
                return []
            }
            return findings.map { finding in
                let instruction = [finding.title, finding.message, finding.suggestedPatch]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                return MinedRuleDraft(
                    title: finding.title,
                    severity: finding.severity,
                    languages: finding.filePath.map { [LanguageMap.language(forPath: $0).rawValue] } ?? [],
                    pathGlobs: finding.filePath.map { [PatchGlobs.glob(forPath: $0)] } ?? ["**/*"],
                    payload: .semantic(instruction: instruction, fewShots: []),
                    sourcePRRefs: [sourceID.rawValue],
                    body: finding.message
                )
            }
        }

        return items.map { item in
            let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = (title?.isEmpty == false ? title : nil) ?? item.sourceLabel
            let instruction = [resolvedTitle, item.body, item.commentsJSON]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let patch = (try? Data(contentsOf: store.blobs.corpusPatchURL(itemID: item.id))) ?? Data()
            return MinedRuleDraft(
                title: resolvedTitle,
                pathGlobs: PatchGlobs.from(patch: patch),
                payload: .semantic(instruction: instruction, fewShots: []),
                sourcePRRefs: [item.sourceLabel],
                body: item.body ?? ""
            )
        }
    }

    private func filterDrafts(_ drafts: [MinedRuleDraft], spec: MineJobSpec) async throws -> [MinedRuleDraft] {
        guard spec.source == .job, let sourceID = spec.sourceJobID else {
            return drafts
        }
        let findings = try await store.findings(jobID: sourceID)
        let feedback = try await store.feedback(jobID: sourceID)
        let sourceJob = try await store.job(id: sourceID)
        return drafts.filter {
            SuggestionFilter.keepJobRule(
                draft: $0,
                findings: findings,
                feedback: feedback,
                risk: sourceJob?.risk
            )
        }
    }

    private func fillInbox(
        items: [CorpusItem],
        spec: MineJobSpec,
        drafts: [MinedRuleDraft],
        workspace: URL,
        jobID: JobID,
        now: Date
    ) async throws -> (inserted: Int, attached: Int) {
        let sourceID = spec.sourceJobID
        var contextTitle: String?
        var contextBody: String?
        if spec.source == .job, let sourceID {
            let indexer = ArchitectureIndexJob(
                store: store,
                embedder: embedder,
                maxChunks: maxChunks,
                skipAgent: skipAgent,
                miner: miner,
                model: model,
                onWarning: { [store, sourceID] message in
                    try? await store.appendEvent(jobID: sourceID, level: .warning, message: message)
                }
            )
            do {
                try await indexSourceJob(sourceID, indexer: indexer)
                try await indexer.embedEnabledRules(try await store.listRules(RuleListFilter(enabled: true)))
            } catch {
                try await store.appendEvent(
                    jobID: sourceID,
                    level: .warning,
                    message: "architecture_index_failed"
                )
            }

            let findings = try await store.findings(jobID: sourceID)
            let feedback = try await store.feedback(jobID: sourceID)
            if let body = SuggestionFilter.contextBody(findings: findings, feedback: feedback) {
                let job = try await store.job(id: sourceID)
                contextTitle = "Notes from \(job?.title ?? sourceID.rawValue)"
                contextBody = body
            }
        }

        let provenance: RuleProvenance = spec.source == .job ? .suggested : .mined
        var candidates: [SuggestionCandidate] = []
        for (index, draft) in drafts.enumerated() {
            candidates.append(
                SuggestionCandidate(
                    id: "sug_rule_\(index)",
                    kind: .rule,
                    title: draft.title,
                    body: draft.body.isEmpty ? PromptBudget.render(
                        Self.rule(
                            from: draft,
                            provenance: provenance,
                            fallbackRefs: fallbackRefs(items: items, spec: spec),
                            now: now
                        )
                    ) : draft.body
                )
            )
        }
        if let contextTitle, let contextBody {
            candidates.append(
                SuggestionCandidate(
                    id: "sug_context",
                    kind: .context,
                    title: contextTitle,
                    body: contextBody
                )
            )
        }

        let endorsedIDs = Set(candidates.map(\.id))
        var keptCandidates = candidates
        if !skipAgent, let suggestionJudge, !candidates.isEmpty, let mineJob = try await store.job(id: jobID) {
            try SuggestionJudge.writeInput(candidates, workspace: workspace)
            let judged = await suggestionJudge.runSuggestionJudge(
                job: mineJob,
                workspace: Workspace(root: workspace)
            )
            keptCandidates = SuggestionJudge.apply(
                outcome: judged.outcome,
                candidates: candidates,
                fallbackIDs: endorsedIDs
            )
            try await store.appendEvent(
                jobID: jobID,
                level: judged.failed ? .warning : .info,
                message: judged.failed ? "suggestion_judge_failed" : "suggestion_judged",
                payloadJSON: SuggestionJudge.eventPayload(
                    candidates: candidates.count,
                    kept: keptCandidates.count,
                    result: judged
                )
            )
        }

        let keptByID = Dictionary(uniqueKeysWithValues: keptCandidates.map { ($0.id, $0) })
        let catalog: (findings: [Finding], feedback: [FindingFeedback])
        if spec.source == .job {
            catalog = try await store.findingsAndFeedback()
        } else {
            catalog = ([], [])
        }
        var inserted = 0
        var attached = 0
        for (index, draft) in drafts.enumerated() {
            let key = "sug_rule_\(index)"
            guard let kept = keptByID[key] else { continue }
            if spec.source == .job {
                let original = candidates[index]
                guard SuggestionFilter.enoughRuleEndorsements(
                    titles: [kept.title, original.title, draft.title],
                    findings: catalog.findings,
                    feedback: catalog.feedback
                ) else { continue }
            }
            var rule = Self.rule(
                from: draft,
                provenance: provenance,
                fallbackRefs: fallbackRefs(items: items, spec: spec),
                now: now
            )
            rule.title = kept.title
            rule.body = kept.body
            if case .semantic(_, let shots) = rule.payload {
                rule.payload = .semantic(instruction: kept.body, fewShots: shots)
            }
            switch try await MinerDedup.upsert(rule, into: store, now: now) {
            case .inserted(let id):
                inserted += 1
                try await insertRuleLearning(
                    ruleID: id,
                    sourceID: sourceID,
                    original: candidates[index],
                    kept: kept,
                    now: now
                )
            case .attached(let id):
                attached += 1
                try await insertRuleLearning(
                    ruleID: id,
                    sourceID: sourceID,
                    original: candidates[index],
                    kept: kept,
                    now: now
                )
            }
        }

        if let kept = keptByID["sug_context"], let contextTitle, let contextBody {
            if try await LearningDedup.alreadySettled(
                store: store,
                kind: .context,
                title: kept.title
            ) {
                return (inserted, attached)
            }
            try await store.insertLearning(
                Learning(
                    jobID: sourceID,
                    kind: .context,
                    title: kept.title,
                    body: kept.body,
                    payloadJSON: Self.json([
                        "kind": "context",
                        "original_title": contextTitle,
                        "original_body": contextBody,
                    ]),
                    createdAt: now
                )
            )
        }
        return (inserted, attached)
    }

    private func insertRuleLearning(
        ruleID: RuleID,
        sourceID: JobID?,
        original: SuggestionCandidate,
        kept: SuggestionCandidate,
        now: Date
    ) async throws {
        if try await LearningDedup.alreadySettled(
            store: store,
            kind: .rule,
            title: kept.title,
            ruleID: ruleID.rawValue
        ) {
            return
        }
        try await store.insertLearning(
            Learning(
                jobID: sourceID,
                kind: .rule,
                title: kept.title,
                body: kept.body,
                payloadJSON: Self.json([
                    "rule_id": ruleID.rawValue,
                    "original_title": original.title,
                    "original_body": original.body,
                ]),
                createdAt: now
            )
        )
    }

    private func indexSourceJob(_ sourceID: JobID, indexer: ArchitectureIndexJob) async throws {
        let sourceWorkspace = store.blobs.workspaceURL(jobID: sourceID.rawValue)
        if workspaceHasTree(sourceWorkspace) {
            try await indexer.run(workspace: Workspace(root: sourceWorkspace), jobID: sourceID)
            return
        }
        let archive = store.blobs.archiveURL(jobID: sourceID.rawValue)
        guard FileManager.default.fileExists(atPath: archive.path) else {
            try await store.appendEvent(
                jobID: sourceID,
                level: .warning,
                message: "architecture_index_failed"
            )
            return
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gegenlesen-reindex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try ArchiveUnpacker().unpack(archive: archive, into: temp)
        try await indexer.run(workspace: Workspace(root: temp), jobID: sourceID)
    }

    private func workspaceHasTree(_ root: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return false }
        let items = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return items.contains { $0 != ".gegenlesen" && $0 != "job" && $0 != "corpus" }
    }

    private func fallbackRefs(items: [CorpusItem], spec: MineJobSpec) -> [String] {
        if spec.source == .job, let id = spec.sourceJobID {
            return [id.rawValue]
        }
        return items.map(\.sourceLabel)
    }

    private static func rule(
        from draft: MinedRuleDraft,
        provenance: RuleProvenance,
        fallbackRefs: [String],
        now: Date
    ) -> Rule {
        let refs = draft.sourcePRRefs.isEmpty ? fallbackRefs : draft.sourcePRRefs
        let id = draft.id?.isValid == true ? draft.id! : RuleID.slug(from: draft.title)
        return Rule(
            id: id,
            title: draft.title,
            severity: draft.severity,
            kind: draft.kind,
            enabled: false,
            provenance: provenance,
            languages: draft.languages,
            pathGlobs: draft.pathGlobs,
            payload: draft.payload,
            examples: draft.examples,
            sourcePRRefs: refs,
            body: draft.body,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private static func encodeFindings(_ findings: [Finding]) -> Data {
        let rows: [[String: Any]] = findings.map { finding in
            var row: [String: Any] = [
                "id": finding.id.rawValue,
                "title": finding.title,
                "message": finding.message,
                "severity": finding.severity.rawValue,
                "phase": finding.phase.rawValue,
                "lifecycle": finding.lifecycle.rawValue,
            ]
            if let slot = finding.reviewerSlot { row["reviewer_slot"] = slot.rawValue }
            if let path = finding.filePath { row["file_path"] = path }
            if let start = finding.startLine { row["start_line"] = start }
            if let end = finding.endLine { row["end_line"] = end }
            if let snippet = finding.snippet { row["snippet"] = snippet }
            if let verdict = finding.judgeVerdict { row["judge_verdict"] = verdict.rawValue }
            if let rationale = finding.judgeRationale { row["judge_rationale"] = rationale }
            if let patch = finding.suggestedPatch { row["suggested_patch"] = patch }
            return row
        }
        return (try? JSONSerialization.data(
            withJSONObject: ["findings": rows],
            options: [.sortedKeys]
        )) ?? Data("{\"findings\":[]}".utf8)
    }
}
