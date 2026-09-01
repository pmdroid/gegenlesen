import Foundation

public struct ArchitectureIndexJob: Sendable {
    public var store: Store
    public var embedder: (any EmbeddingClient)?
    public var maxChunks: Int
    public var skipAgent: Bool
    public var miner: (any MinerRunning)?
    public var engine: String
    public var model: String
    public var onWarning: (@Sendable (String) async -> Void)?
    public var onInfo: (@Sendable (String) async -> Void)?

    public init(
        store: Store,
        embedder: (any EmbeddingClient)? = nil,
        maxChunks: Int = 20_000,
        skipAgent: Bool = true,
        miner: (any MinerRunning)? = nil,
        engine: String = AgentEngineID.opencode,
        model: String = "openrouter/openai/gpt-5.6-terra",
        onWarning: (@Sendable (String) async -> Void)? = nil,
        onInfo: (@Sendable (String) async -> Void)? = nil
    ) {
        self.store = store
        self.embedder = embedder
        self.maxChunks = maxChunks
        self.skipAgent = skipAgent
        self.miner = miner
        self.engine = engine
        self.model = model
        self.onWarning = onWarning
        self.onInfo = onInfo
    }

    public static func chunkID(kind: ChunkKind, ref: String, ordinal: Int) -> String {
        "\(kind.rawValue):\(ref):\(ordinal)"
    }

    @discardableResult
    public func run(workspace: Workspace, jobID: JobID?) async throws -> String {
        try await indexFiles(workspace: workspace)
        let fallback = renderDraft(modules: walk(workspace.root).modules, skipAgent: skipAgent)
        var draft = fallback
        var storeDraft = true
        if let stored = try await storedCard(jobID: jobID) {
            draft = stored
            await onInfo?("architecture_cached")
        } else if !skipAgent, miner != nil, let jobID {
            if let mined = await draftFromMiner(workspace: workspace, jobID: jobID, fallback: fallback) {
                draft = mined
                await onInfo?("architecture_mined")
            } else {
                draft = fallback
                storeDraft = false
                await onWarning?("architecture_index_failed")
            }
        }
        let dest = workspace.root.appendingPathComponent(".gegenlesen/architecture-draft.md")
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try draft.write(to: dest, atomically: true, encoding: .utf8)
        if storeDraft {
            try await upsertArchitectureLearning(draft: draft, jobID: jobID)
        }
        return draft
    }

    public func embedNote(_ note: ContextNote) async throws {
        let kind: ChunkKind = note.kind == .architecture ? .architecture : .user
        let pieces = TextChunker.chunks("\(note.title)\n\n\(note.body)")
        var drafts: [ContextChunk] = []
        for (ordinal, piece) in pieces.enumerated() {
            drafts.append(
                ContextChunk(
                    id: Self.chunkID(kind: kind, ref: note.id, ordinal: ordinal),
                    kind: kind,
                    ref: note.id,
                    ordinal: ordinal,
                    text: piece,
                    contentSHA256: ContentHash.sha256(Data(piece.utf8))
                )
            )
        }
        try await upsertIncremental(
            kind: kind,
            keepRefs: [note.id],
            completeRefs: [note.id],
            pruneMissingRefs: false,
            drafts: drafts
        )
    }

    public func embedRule(_ rule: Rule) async throws {
        if !rule.enabled || !rule.payload.isSemantic || rule.deletedAt != nil {
            try await store.deleteChunks(kind: .rule, ref: rule.id.rawValue)
            return
        }
        let text = PromptBudget.render(rule)
        try await upsertIncremental(
            kind: .rule,
            keepRefs: [rule.id.rawValue],
            completeRefs: [rule.id.rawValue],
            pruneMissingRefs: false,
            drafts: [
                ContextChunk(
                    id: Self.chunkID(kind: .rule, ref: rule.id.rawValue, ordinal: 0),
                    kind: .rule,
                    ref: rule.id.rawValue,
                    text: text,
                    contentSHA256: ContentHash.sha256(Data(text.utf8))
                ),
            ]
        )
    }

    public func embedEnabledRules(_ rules: [Rule]) async throws {
        for rule in rules {
            try await embedRule(rule)
        }
    }

    private func indexFiles(workspace: Workspace) async throws {
        let walked = walk(workspace.root)
        var drafts: [ContextChunk] = []
        var completeRefs = Set<String>()
        let seenRefs = Set(walked.files.map(\.relative))
        drafts.reserveCapacity(min(walked.files.count, maxChunks))
        var hitCap = false
        for file in walked.files {
            if hitCap { continue }
            guard let data = try? Data(contentsOf: file.url),
                  let text = String(data: data, encoding: .utf8),
                  !text.isEmpty
            else { continue }
            let sha = ContentHash.sha256(data)
            let pieces = TextChunker.chunks(text)
            var addedAll = true
            for (ordinal, piece) in pieces.enumerated() {
                if drafts.count >= maxChunks {
                    hitCap = true
                    addedAll = false
                    break
                }
                drafts.append(
                    ContextChunk(
                        id: Self.chunkID(kind: .file, ref: file.relative, ordinal: ordinal),
                        kind: .file,
                        ref: file.relative,
                        ordinal: ordinal,
                        text: piece,
                        contentSHA256: sha
                    )
                )
            }
            if addedAll {
                completeRefs.insert(file.relative)
            }
        }
        try await upsertIncremental(
            kind: .file,
            keepRefs: seenRefs,
            completeRefs: completeRefs,
            pruneMissingRefs: true,
            drafts: drafts
        )
    }

    private func upsertIncremental(
        kind: ChunkKind,
        keepRefs: Set<String>,
        completeRefs: Set<String>,
        pruneMissingRefs: Bool,
        drafts: [ContextChunk]
    ) async throws {
        let existing = Dictionary(
            uniqueKeysWithValues: (try await store.chunks(kind: kind)).map { ($0.id, $0) }
        )
        var pending: [(index: Int, text: String)] = []
        var ready = drafts
        for (index, draft) in drafts.enumerated() {
            if let prior = existing[draft.id] {
                ready[index].embedding = prior.embedding
                ready[index].embeddingModel = prior.embeddingModel
                let modelMatches = embedder == nil || prior.embeddingModel == embedder?.model
                if prior.contentSHA256 == draft.contentSHA256, prior.embedding != nil, modelMatches {
                    continue
                }
            }
            if embedder != nil {
                pending.append((index, draft.text))
            }
        }
        if let embedder, !pending.isEmpty {
            do {
                let texts = pending.map(\.text)
                var offset = 0
                var short = false
                while offset < texts.count {
                    let end = min(offset + 32, texts.count)
                    let expected = end - offset
                    let vectors = try await embedder.embed(Array(texts[offset..<end]))
                    if vectors.count < expected {
                        short = true
                    }
                    for (inner, vector) in vectors.enumerated() {
                        let slot = pending[offset + inner].index
                        ready[slot].embedding = EmbeddingVector.encode(vector)
                        ready[slot].embeddingModel = embedder.model
                    }
                    offset = end
                }
                if short {
                    await onWarning?("embedding_failed")
                }
            } catch {
                await onWarning?("embedding_failed")
            }
        }
        try await store.upsertChunks(ready)
        let newIDs = Set(ready.map(\.id))
        var stale: [String] = []
        for old in existing.values {
            if completeRefs.contains(old.ref), !newIDs.contains(old.id) {
                stale.append(old.id)
            } else if pruneMissingRefs, !keepRefs.contains(old.ref) {
                stale.append(old.id)
            }
        }
        try await store.deleteChunks(ids: stale)
    }

    private func storedCard(jobID: JobID?) async throws -> String? {
        let repository: String?
        if let jobID {
            repository = try await store.job(id: jobID)?.repository
        } else {
            repository = nil
        }
        if let accepted = try await store.acceptedArchitectureNote(repository: repository) {
            let body = accepted.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { return accepted.body }
        }
        if repository != nil,
           let global = try await store.acceptedArchitectureNote(repository: nil) {
            let body = global.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { return global.body }
        }
        if let item = try await pendingArchitecture(repository: repository, allowUnscoped: true) {
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { return item.body }
        }
        return nil
    }

    private func pendingArchitecture(repository: String?, allowUnscoped: Bool) async throws -> Learning? {
        let pending = try await store.listLearnings(status: .pending, kind: .architecture)
        var unscoped: Learning?
        for item in pending {
            let itemRepo = try await learningRepository(item)
            if itemRepo == repository {
                return item
            }
            if itemRepo == nil, unscoped == nil {
                unscoped = item
            }
        }
        if allowUnscoped { return unscoped }
        return nil
    }

    private func learningRepository(_ item: Learning) async throws -> String? {
        guard let jobID = item.jobID else { return nil }
        return try await store.job(id: jobID)?.repository
    }

    private func draftFromMiner(workspace: Workspace, jobID: JobID, fallback: String) async -> String? {
        let prompt = """
            Draft a short architecture card for this repository.
            Cover layers, entrypoints, logging conventions, and forbidden areas.
            Write ONLY `.gegenlesen/architecture-draft.md` as markdown.
            Do not edit other files.
            """
        do {
            try FileManager.default.createDirectory(
                at: workspace.root.appendingPathComponent(".gegenlesen", isDirectory: true),
                withIntermediateDirectories: true
            )
            try prompt.write(
                to: workspace.root.appendingPathComponent(".gegenlesen/prompt.md"),
                atomically: true,
                encoding: .utf8
            )
            try fallback.write(
                to: workspace.root.appendingPathComponent(".gegenlesen/architecture-draft.md"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            return nil
        }
        guard let miner else { return nil }
        let result = await miner.runMiner(
            jobID: jobID,
            workspace: workspace,
            engine: engine,
            model: model,
            isCancelled: nil
        )
        if result.failed {
            return nil
        }
        let dest = workspace.root.appendingPathComponent(".gegenlesen/architecture-draft.md")
        if let text = try? String(contentsOf: dest, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return nil
    }

    private func upsertArchitectureLearning(draft: String, jobID: JobID?) async throws {
        let hash = ContentHash.sha256(Data(draft.utf8))
        let repository: String?
        if let jobID {
            repository = try await store.job(id: jobID)?.repository
        } else {
            repository = nil
        }
        if try await LearningDedup.dismissedArchitecture(store: store, bodyHash: hash) {
            return
        }
        if let accepted = try await store.acceptedArchitectureNote(repository: repository) {
            let acceptedHash = ContentHash.sha256(Data(accepted.body.utf8))
            if acceptedHash == hash { return }
        }
        if var existing = try await pendingArchitecture(repository: repository, allowUnscoped: repository == nil) {
            existing.body = draft
            existing.title = "Architecture card"
            try await store.updateLearning(existing)
            return
        }
        try await store.insertLearning(
            Learning(
                jobID: jobID,
                kind: .architecture,
                title: "Architecture card",
                body: draft,
                payloadJSON: #"{"kind":"architecture"}"#
            )
        )
    }

    private struct WalkedFile {
        var relative: String
        var url: URL
    }

    private struct WalkResult {
        var files: [WalkedFile]
        var modules: [String]
    }

    private func walk(_ root: URL) -> WalkResult {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return WalkResult(files: [], modules: topLevelDirs(root))
        }
        var files: [WalkedFile] = []
        var modules = Set(topLevelDirs(root))
        while let url = enumerator.nextObject() as? URL {
            let relative = PathGlob.normalize(url.path.replacingOccurrences(of: root.path + "/", with: ""))
            if PathGlob.defaultIgnores.matches(relative) {
                enumerator.skipDescendants()
                continue
            }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isFile else { continue }
            if relative == "Package.swift" || relative.hasSuffix("/Package.swift")
                || relative == "go.mod" || relative.hasSuffix("/go.mod")
                || relative == "package.json" || relative.hasSuffix("/package.json") {
                modules.insert(relative)
            }
            files.append(WalkedFile(relative: relative, url: url))
        }
        files.sort { $0.relative < $1.relative }
        return WalkResult(files: files, modules: modules.sorted())
    }

    private func topLevelDirs(_ root: URL) -> [String] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.compactMap { url in
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name == ".gegenlesen" { return nil }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir ? name : nil
        }.sorted()
    }

    private func renderDraft(modules: [String], skipAgent: Bool) -> String {
        var lines = [
            "# Architecture draft",
            "",
            skipAgent
                ? "Generated locally (GEGENLESEN_SKIP_AGENT). Operator should edit before accept."
                : "Drafted for operator review. Do not overwrite the accepted card until accepted.",
            "",
            "## Modules",
        ]
        if modules.isEmpty {
            lines.append("- (none detected)")
        } else {
            lines.append(contentsOf: modules.map { "- \($0)" })
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
