import Foundation
import Testing
@testable import MeisterCore

@Suite
struct EmbeddingRetrieveTests {
    @Test
    func cosinePrefersCloserVector() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        let query: [Float] = [0.9, 0.1, 0]
        #expect(EmbeddingVector.cosine(query, a) > EmbeddingVector.cosine(query, b))
        let encoded = EmbeddingVector.encode(a)
        #expect(EmbeddingVector.decode(encoded) == a)
    }

    @Test
    func retrieveTopKFromBlobsAndAlwaysInclude() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let near = ContextChunk(
                id: "near",
                kind: .file,
                ref: "Sources/Logger.swift",
                text: "project logger",
                embedding: EmbeddingVector.encode([1, 0, 0]),
                contentSHA256: "aa"
            )
            let far = ContextChunk(
                id: "far",
                kind: .file,
                ref: "README.md",
                text: "unrelated",
                embedding: EmbeddingVector.encode([0, 1, 0]),
                contentSHA256: "bb"
            )
            let note = ContextNote(
                id: "note-always",
                title: "Always on",
                body: "operator house note",
                alwaysInclude: true
            )
            let alwaysChunk = ContextChunk(
                id: "always",
                kind: .user,
                ref: note.id,
                text: note.body,
                embedding: EmbeddingVector.encode([0, 0, 1]),
                contentSHA256: "cc"
            )
            try await store.insertContextNote(note)
            try await store.upsertChunks([near, far, alwaysChunk])

            let hits = try await store.retrieveChunks(query: [1, 0, 0], k: 1)
            #expect(hits.first?.chunk.id == "near")
            #expect(hits.contains { $0.chunk.id == "always" })
            #expect(!hits.contains { $0.chunk.id == "far" })
        }
    }

    @Test
    func architectureIndexAndContextPackUseTempWorkspace() async throws {
        try await withTempDir("arch-index") { root in
            try writeFile("Package.swift", "// swift-tools-version: 6.0\n", in: root)
            try writeFile("Sources/App/Main.swift", "print(\"hi\")\n", in: root)
            try await withTempDataDir { dir in
                let store = try Store.open(dataDir: dir)
                let job = try await ArchitectureIndexJob(
                    store: store,
                    embedder: HashEmbeddingClient(dimensions: 16),
                    skipAgent: true
                ).run(workspace: Workspace(root: root), jobID: nil)
                #expect(job.contains("Package.swift") || job.contains("Sources"))
                let learnings = try await store.listLearnings(status: .pending, kind: .architecture)
                #expect(learnings.count == 1)
                let packed = ContextPack.markdown(notes: [], hits: [])
                #expect(packed.contains("Project context"))
            }
        }
    }
}
