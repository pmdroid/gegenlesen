import Foundation

public struct ArchitectureIndexJob: Sendable {
    public var store: Store
    public var embedder: (any EmbeddingClient)?
    public var maxChunks: Int
    public var skipAgent: Bool

    public init(
        store: Store,
        embedder: (any EmbeddingClient)? = nil,
        maxChunks: Int = 20_000,
        skipAgent: Bool = true
    ) {
        self.store = store
        self.embedder = embedder
        self.maxChunks = maxChunks
        self.skipAgent = skipAgent
    }

    @discardableResult
    public func run(workspace: Workspace, jobID: JobID?) async throws -> String {
        let walked = walk(workspace.root)
        var chunks: [ContextChunk] = []
        chunks.reserveCapacity(min(walked.files.count, maxChunks))
        for file in walked.files {
            if chunks.count >= maxChunks { break }
            guard let data = try? Data(contentsOf: file.url),
                  let text = String(data: data, encoding: .utf8),
                  !text.isEmpty
            else { continue }
            let sha = ContentHash.sha256(data)
            for (ordinal, piece) in TextChunker.chunks(text).enumerated() {
                if chunks.count >= maxChunks { break }
                var embedding: Data?
                var model: String?
                if let embedder, let vector = try? await embedder.embed([piece]).first {
                    embedding = EmbeddingVector.encode(vector)
                    model = embedder.model
                }
                chunks.append(
                    ContextChunk(
                        kind: .file,
                        ref: file.relative,
                        ordinal: ordinal,
                        text: piece,
                        embedding: embedding,
                        embeddingModel: model,
                        contentSHA256: sha
                    )
                )
            }
        }
        try await store.deleteChunks(kind: .file)
        try await store.upsertChunks(chunks)

        let draft = renderDraft(modules: walked.modules, skipAgent: skipAgent)
        let dest = workspace.root.appendingPathComponent(".meister/architecture-draft.md")
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try draft.write(to: dest, atomically: true, encoding: .utf8)

        let pending = try await store.listLearnings(status: .pending, kind: .architecture)
        if pending.isEmpty {
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
        return draft
    }

    public func embedNote(_ note: ContextNote) async throws {
        let kind: ChunkKind = note.kind == .architecture ? .architecture : .user
        try await store.deleteChunks(kind: kind, ref: note.id)
        let pieces = TextChunker.chunks("\(note.title)\n\n\(note.body)")
        var chunks: [ContextChunk] = []
        for (ordinal, piece) in pieces.enumerated() {
            var embedding: Data?
            var model: String?
            if let embedder, let vector = try? await embedder.embed([piece]).first {
                embedding = EmbeddingVector.encode(vector)
                model = embedder.model
            }
            chunks.append(
                ContextChunk(
                    kind: kind,
                    ref: note.id,
                    ordinal: ordinal,
                    text: piece,
                    embedding: embedding,
                    embeddingModel: model,
                    contentSHA256: ContentHash.sha256(Data(piece.utf8))
                )
            )
        }
        try await store.upsertChunks(chunks)
    }

    public func embedRule(_ rule: Rule) async throws {
        guard rule.enabled, rule.payload.isSemantic else { return }
        let text = PromptBudget.render(rule)
        var embedding: Data?
        var model: String?
        if let embedder, let vector = try? await embedder.embed([text]).first {
            embedding = EmbeddingVector.encode(vector)
            model = embedder.model
        }
        try await store.deleteChunks(kind: .rule, ref: rule.id.rawValue)
        try await store.upsertChunks([
            ContextChunk(
                kind: .rule,
                ref: rule.id.rawValue,
                text: text,
                embedding: embedding,
                embeddingModel: model,
                contentSHA256: ContentHash.sha256(Data(text.utf8))
            ),
        ])
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
