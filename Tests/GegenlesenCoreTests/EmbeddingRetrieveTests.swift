import Foundation
import Testing
@testable import GegenlesenCore

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
                id: "always-0",
                kind: .user,
                ref: note.id,
                ordinal: 0,
                text: "part one",
                embedding: EmbeddingVector.encode([0, 0, 1]),
                contentSHA256: "cc"
            )
            let alwaysChunk2 = ContextChunk(
                id: "always-1",
                kind: .user,
                ref: note.id,
                ordinal: 1,
                text: "part two",
                embedding: EmbeddingVector.encode([0, 0, 1]),
                contentSHA256: "dd"
            )
            try await store.insertContextNote(note)
            try await store.upsertChunks([near, far, alwaysChunk, alwaysChunk2])

            let hits = try await store.retrieveChunks(query: [1, 0, 0], k: 1)
            #expect(hits.first?.chunk.id == "near")
            #expect(hits.contains { $0.chunk.id == "always-0" })
            #expect(hits.contains { $0.chunk.id == "always-1" })
            #expect(!hits.contains { $0.chunk.id == "far" })
        }
    }

    @Test
    func incrementalIndexSkipsUnchangedSHA() async throws {
        try await withTempDir("arch-incr") { root in
            try writeFile("Sources/App/Main.swift", "print(\"hi\")\n", in: root)
            try await withTempDataDir { dir in
                let store = try Store.open(dataDir: dir)
                let embedder = CountingEmbedder()
                let job = ArchitectureIndexJob(
                    store: store,
                    embedder: embedder,
                    skipAgent: true
                )
                _ = try await job.run(workspace: Workspace(root: root), jobID: nil)
                let first = embedder.callCount
                #expect(first >= 1)
                _ = try await job.run(workspace: Workspace(root: root), jobID: nil)
                let second = embedder.callCount
                #expect(second == first)
                let pending = try await store.listLearnings(status: .pending, kind: .architecture)
                #expect(pending.count == 1)
            }
        }
    }

    @Test
    func nilEmbedderKeepsPriorBlobsAndCapDoesNotDropUnvisited() async throws {
        try await withTempDir("arch-keep") { root in
            try writeFile("a.swift", "aaa\n", in: root)
            try writeFile("b.swift", "bbb\n", in: root)
            try await withTempDataDir { dir in
                let store = try Store.open(dataDir: dir)
                _ = try await ArchitectureIndexJob(
                    store: store,
                    embedder: HashEmbeddingClient(dimensions: 16),
                    skipAgent: true
                ).run(workspace: Workspace(root: root), jobID: nil)
                let before = try await store.chunks(kind: .file)
                #expect(before.count == 2)
                #expect(before.allSatisfy { $0.embedding != nil })

                _ = try await ArchitectureIndexJob(
                    store: store,
                    embedder: nil,
                    skipAgent: true
                ).run(workspace: Workspace(root: root), jobID: nil)
                let afterNil = try await store.chunks(kind: .file)
                #expect(afterNil.count == 2)
                #expect(afterNil.allSatisfy { $0.embedding != nil })

                _ = try await ArchitectureIndexJob(
                    store: store,
                    embedder: nil,
                    maxChunks: 1,
                    skipAgent: true
                ).run(workspace: Workspace(root: root), jobID: nil)
                let afterCap = try await store.chunks(kind: .file)
                #expect(afterCap.count == 2)
                #expect(afterCap.allSatisfy { $0.embedding != nil })
            }
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

    @Test
    func architectureMinerRunsOnceThenReusesStoredCard() async throws {
        try await withTempDir("arch-once") { root in
            try writeFile("Package.swift", "// swift-tools-version: 6.0\n", in: root)
            try await withTempDataDir { dir in
                let store = try Store.open(dataDir: dir)
                let now = Date()
                let job = Job(
                    id: JobID.generate(),
                    createdAt: now,
                    updatedAt: now,
                    status: .queued,
                    scope: .full,
                    repository: "github.com/acme/meister",
                    reviewerAModelID: "a",
                    reviewerBModelID: "b",
                    judgeModelID: "j"
                )
                try await store.insertJob(job)
                let miner = CountingArchitectureMiner()
                let indexer = ArchitectureIndexJob(
                    store: store,
                    skipAgent: false,
                    miner: miner
                )
                let first = try await indexer.run(workspace: Workspace(root: root), jobID: job.id)
                #expect(miner.calls == 1)
                #expect(first.contains("mined card"))
                let pending = try await store.listLearnings(status: .pending, kind: .architecture)
                #expect(pending.count == 1)

                let second = try await indexer.run(workspace: Workspace(root: root), jobID: job.id)
                #expect(miner.calls == 1)
                #expect(second.contains("mined card"))
            }
        }
    }

    @Test
    func acceptedArchitectureCardSkipsMiner() async throws {
        try await withTempDir("arch-accepted") { root in
            try writeFile("Package.swift", "// swift-tools-version: 6.0\n", in: root)
            try await withTempDataDir { dir in
                let store = try Store.open(dataDir: dir)
                try await store.insertContextNote(
                    ContextNote(
                        kind: .architecture,
                        title: "Architecture card",
                        body: "stored layers and entrypoints",
                        repository: "github.com/acme/meister"
                    )
                )
                let now = Date()
                let job = Job(
                    id: JobID.generate(),
                    createdAt: now,
                    updatedAt: now,
                    status: .queued,
                    scope: .full,
                    repository: "github.com/acme/meister",
                    reviewerAModelID: "a",
                    reviewerBModelID: "b",
                    judgeModelID: "j"
                )
                try await store.insertJob(job)
                let miner = CountingArchitectureMiner()
                let draft = try await ArchitectureIndexJob(
                    store: store,
                    skipAgent: false,
                    miner: miner
                ).run(workspace: Workspace(root: root), jobID: job.id)
                #expect(miner.calls == 0)
                #expect(draft.contains("stored layers and entrypoints"))
            }
        }
    }
}

private final class CountingArchitectureMiner: MinerRunning, @unchecked Sendable {
    var calls = 0
    var card = "# Architecture draft\n\nmined card\n"

    func runMiner(
        jobID: JobID,
        workspace: Workspace,
        model: String,
        isCancelled: (@Sendable () async -> Bool)?
    ) async -> MinerRunResult {
        calls += 1
        let dest = workspace.root.appendingPathComponent(".gegenlesen/architecture-draft.md")
        try? FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? card.write(to: dest, atomically: true, encoding: .utf8)
        return MinerRunResult(containerName: "mine", failed: false)
    }
}

final class CountingEmbedder: EmbeddingClient, @unchecked Sendable {
    let model = "hash"
    let dimensions = 16
    nonisolated(unsafe) private(set) var callCount = 0

    func embed(_ texts: [String]) async throws -> [[Float]] {
        callCount += 1
        return texts.map { EmbeddingVector.hashEmbedding($0, dimensions: dimensions) }
    }
}
