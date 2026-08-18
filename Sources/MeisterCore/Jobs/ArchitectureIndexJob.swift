import Foundation

public struct ArchitectureIndexJob: Sendable {
    public var store: Store
    public var embedder: (any EmbeddingClient)?
    public var maxChunks: Int
    public var skipAgent: Bool
    public var miner: (any MinerRunning)?
    public var model: String
    public var onWarning: (@Sendable (String) async -> Void)?

    public init(
        store: Store,
        embedder: (any EmbeddingClient)? = nil,
        maxChunks: Int = 20_000,
        skipAgent: Bool = true,
        miner: (any MinerRunning)? = nil,
        model: String = "anthropic/claude-sonnet-4-5",
        onWarning: (@Sendable (String) async -> Void)? = nil
    ) {
        self.store = store
        self.embedder = embedder
        self.maxChunks = maxChunks
        self.skipAgent = skipAgent
        self.miner = miner
        self.model = model
        self.onWarning = onWarning
    }

    public static func chunkID(kind: ChunkKind, ref: String, ordinal: Int) -> String {
        "\(kind.rawValue):\(ref):\(ordinal)"
    }

    @discardableResult
    public func run(workspace: Workspace, jobID: JobID?) async throws -> String {
        try await indexFiles(workspace: workspace)
        var draft = renderDraft(modules: walk(workspace.root).modules, skipAgent: skipAgent)
        if !skipAgent, let miner, let jobID {
            draft = await draftFromMiner(workspace: workspace, jobID: jobID, fallback: draft)
        }
        let dest = workspace.root.appendingPathComponent(".meister/architecture-draft.md")
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try draft.write(to: dest, atomically: true, encoding: .utf8)
        try await upsertArchitectureLearning(draft: draft, jobID: jobID)
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
        try await upsertIncremental(kind: kind, keepRefs: [note.id], pruneMissingRefs: false, drafts: drafts)
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
        drafts.reserveCapacity(min(walked.files.count, maxChunks))
        for file in walked.files {
            if drafts.count >= maxChunks { break }
            guard let data = try? Data(contentsOf: file.url),
                  let text = String(data: data, encoding: .utf8),
                  !text.isEmpty
            else { continue }
            let sha = ContentHash.sha256(data)
            for (ordinal, piece) in TextChunker.chunks(text).enumerated() {
                if drafts.count >= maxChunks { break }
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
        }
        try await upsertIncremental(
            kind: .file,
            keepRefs: Set(drafts.map(\.ref)),
            pruneMissingRefs: true,
            drafts: drafts
        )
    }

    private func upsertIncremental(
        kind: ChunkKind,
        keepRefs: Set<String>,
        pruneMissingRefs: Bool,
        drafts: [ContextChunk]
    ) async throws {
        let existing = Dictionary(
            uniqueKeysWithValues: (try await store.chunks(kind: kind)).map { ($0.id, $0) }
        )
        let modelName = embedder?.model
        var pending: [(index: Int, text: String)] = []
        var ready = drafts
        for (index, draft) in drafts.enumerated() {
            if let prior = existing[draft.id],
               prior.contentSHA256 == draft.contentSHA256,
               prior.embeddingModel == modelName,
               prior.embedding != nil {
                ready[index].embedding = prior.embedding
                ready[index].embeddingModel = prior.embeddingModel
                continue
            }
            if embedder != nil {
                pending.append((index, draft.text))
            }
        }
        if let embedder, !pending.isEmpty {
            do {
                let texts = pending.map(\.text)
                var offset = 0
                while offset < texts.count {
                    let end = min(offset + 32, texts.count)
                    let vectors = try await embedder.embed(Array(texts[offset..<end]))
                    for (inner, vector) in vectors.enumerated() {
                        let slot = pending[offset + inner].index
                        ready[slot].embedding = EmbeddingVector.encode(vector)
                        ready[slot].embeddingModel = embedder.model
                    }
                    offset = end
                }
            } catch {
                await onWarning?("embedding_failed")
                for item in pending {
                    if let prior = existing[ready[item.index].id] {
                        ready[item.index].embedding = prior.embedding
                        ready[item.index].embeddingModel = prior.embeddingModel
                    }
                }
            }
        }
        try await store.upsertChunks(ready)
        let newIDs = Set(ready.map(\.id))
        var stale: [String] = []
        for old in existing.values {
            if keepRefs.contains(old.ref), !newIDs.contains(old.id) {
                stale.append(old.id)
            } else if pruneMissingRefs, !keepRefs.contains(old.ref) {
                stale.append(old.id)
            }
        }
        try await store.deleteChunks(ids: stale)
    }

    private func draftFromMiner(workspace: Workspace, jobID: JobID, fallback: String) async -> String {
        let prompt = """
            Draft a short architecture card for this repository.
            Cover layers, entrypoints, logging conventions, and forbidden areas.
            Write ONLY `.meister/architecture-draft.md` as markdown.
            Do not edit other files.
            """
        do {
            try FileManager.default.createDirectory(
                at: workspace.root.appendingPathComponent(".meister", isDirectory: true),
                withIntermediateDirectories: true
            )
            try prompt.write(
                to: workspace.root.appendingPathComponent(".meister/prompt.md"),
                atomically: true,
                encoding: .utf8
            )
            try fallback.write(
                to: workspace.root.appendingPathComponent(".meister/architecture-draft.md"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            await onWarning?("architecture_index_failed")
            return fallback
        }
        guard let miner else { return fallback }
        let result = await miner.runMiner(
            jobID: jobID,
            workspace: workspace,
            model: model,
            isCancelled: nil
        )
        if result.failed {
            await onWarning?("architecture_index_failed")
            return fallback
        }
        let dest = workspace.root.appendingPathComponent(".meister/architecture-draft.md")
        if let text = try? String(contentsOf: dest, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return fallback
    }

    private func upsertArchitectureLearning(draft: String, jobID: JobID?) async throws {
        let hash = ContentHash.sha256(Data(draft.utf8))
        if let accepted = try await store.acceptedArchitectureNote() {
            let acceptedHash = ContentHash.sha256(Data(accepted.body.utf8))
            if acceptedHash == hash { return }
        }
        let pending = try await store.listLearnings(status: .pending, kind: .architecture)
        if var existing = pending.first {
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
        return WalkResult(files: files, modules: modules.sorted())
    }

    private func topLevelDirs(_ root: URL) -> [String] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.compactMap { url in
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name == ".meister" { return nil }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir ? name : nil
        }.sorted()
    }

    private func renderDraft(modules: [String], skipAgent: Bool) -> String {
        var lines = [
            "# Architecture draft",
            "",
            skipAgent
                ? "Generated locally (MEISTER_SKIP_AGENT). Operator should edit before accept."
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
