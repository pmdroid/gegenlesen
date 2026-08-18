import Foundation

public struct MineCorpusPipeline: Sendable {
    public var store: Store
    public var skipAgent: Bool
    public var miner: (any MinerRunning)?
    public var model: String

    public init(
        store: Store,
        skipAgent: Bool,
        miner: (any MinerRunning)? = nil,
        model: String
    ) {
        self.store = store
        self.skipAgent = skipAgent
        self.miner = miner
        self.model = model
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
            try stage(items: items, spec: spec, workspace: workspaceURL)

            var drafts: [MinedRuleDraft]
            if skipAgent || miner == nil {
                drafts = try await deterministicDrafts(items: items, spec: spec)
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
                if result.failed {
                    _ = try await store.finishJob(
                        id: jobID,
                        status: .failed,
                        errorMessage: result.errorMessage ?? "miner_failed"
                    )
                    try await store.appendEvent(jobID: jobID, level: .error, message: result.errorMessage ?? "miner_failed")
                    return
                }
                let minedURL = workspaceURL.appendingPathComponent(".meister/mined-rules.json")
                if let data = try? Data(contentsOf: minedURL), !data.isEmpty {
                    drafts = (try? MinedRulesFile.parse(data)) ?? []
                } else {
                    drafts = try await deterministicDrafts(items: items, spec: spec)
                }
            }

            let provenance: RuleProvenance = spec.source == .job ? .suggested : .mined
            let now = Date()
            var inserted = 0
            var attached = 0
            for draft in drafts {
                let rule = Self.rule(
                    from: draft,
                    provenance: provenance,
                    fallbackRefs: fallbackRefs(items: items, spec: spec),
                    now: now
                )
                switch try await MinerDedup.upsert(rule, into: store, now: now) {
                case .inserted:
                    inserted += 1
                case .attached:
                    attached += 1
                }
            }

            try await store.markCorpusMined(ids: items.map(\.id), at: now)
            try await store.appendEvent(
                jobID: jobID,
                level: .info,
                message: "mine_done",
                payloadJSON: #"{"inserted":\#(inserted),"attached":\#(attached)}"#
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

    private func stage(items: [CorpusItem], spec: MineJobSpec, workspace: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: workspace.appendingPathComponent(".meister", isDirectory: true),
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
        }
        let prompt = """
            Extract candidate review rules from this workspace.
            Write only `.meister/mined-rules.json` as `{"rules":[...]}`.
            Each rule must include title, path_globs, and a semantic instruction.
            Set enabled to false. Do not edit other files.
            """
        try prompt.write(
            to: workspace.appendingPathComponent(".meister/prompt.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func deterministicDrafts(items: [CorpusItem], spec: MineJobSpec) async throws -> [MinedRuleDraft] {
        if spec.source == .job, let sourceID = spec.sourceJobID {
            let findings = try await store.findings(jobID: sourceID)
            if findings.isEmpty {
                if let job = try await store.job(id: sourceID), let title = job.title, !title.isEmpty {
                    return [
                        MinedRuleDraft(
                            title: title,
                            payload: .semantic(instruction: title, fewShots: []),
                            sourcePRRefs: [sourceID.rawValue],
                            body: title
                        ),
                    ]
                }
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
                    pathGlobs: Self.globs(for: finding.filePath),
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
            return MinedRuleDraft(
                title: resolvedTitle,
                payload: .semantic(instruction: instruction, fewShots: []),
                sourcePRRefs: [item.sourceLabel],
                body: item.body ?? ""
            )
        }
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

    private static func globs(for path: String?) -> [String] {
        guard let path, let slash = path.lastIndex(of: "/") else {
            if let path, path.contains(".") {
                return ["**/*.\(URL(fileURLWithPath: path).pathExtension)"]
            }
            return ["**/*"]
        }
        let name = String(path[path.index(after: slash)...])
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return ["**/*\(name[dot...])"]
        }
        return ["**/*"]
    }
}
