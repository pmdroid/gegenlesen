import Foundation
import Testing
@testable import MeisterCore

@Suite
struct ReviewPipelineAgentTests {
    @Test
    func skipAgentStillSucceedsWithoutReviewer() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let job = queuedJob()
            try await store.insertJob(job)
            try Data("not-a-tar".utf8).write(to: store.blobs.archiveURL(jobID: job.id.rawValue))
            let pipeline = ReviewPipeline(store: store, skipAgent: true)
            try await pipeline.run(jobID: job.id)
            let after = try await store.job(id: job.id)
            #expect(after?.status == .failed)
        }
    }

    @Test
    func reviewerFindingsPersistAndJobSucceeds() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let workspace = store.blobs.workspaceURL(jobID: "will-replace")
            _ = workspace
            try await withTempDir("pipe-agent") { repo in
                try writeFile("Sources/A.swift", "print(2)\n", in: repo)
                try writeFile(
                    ".meister/diff.patch",
                    """
                    diff --git a/Sources/A.swift b/Sources/A.swift
                    new file mode 100644
                    --- /dev/null
                    +++ b/Sources/A.swift
                    @@ -0,0 +1 @@
                    +print(2)
                    """,
                    in: repo
                )
                let archive = dir.appendingPathComponent("change.tar.gz")
                try gzipTarCreate(from: repo, to: archive)

                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))

                let fake = FakeReviewer()
                let pipeline = ReviewPipeline(
                    store: store,
                    skipAgent: false,
                    reviewer: fake
                )
                try await pipeline.run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .succeeded)
                #expect(after.containerNameA == "meister-review-\(job.id.rawValue)-a")
                let findings = try await store.findings(jobID: job.id)
                #expect(findings.contains { $0.phase == .agent && $0.reviewerSlot == .modelA })
            }
        }
    }
}

struct FakeReviewer: ReviewerRunning {
    func run(_ request: AgentReviewRequest) async -> AgentReviewResult {
        let finding = Finding(
            id: FindingID.generate(),
            jobID: request.job.id,
            phase: .agent,
            reviewerSlot: .modelA,
            severity: .info,
            title: "note",
            message: "from fake reviewer",
            filePath: "Sources/A.swift",
            startLine: 1,
            endLine: 1,
            snippet: "print(2)",
            createdAt: Date()
        )
        return AgentReviewResult(
            findings: [finding],
            validFileCount: 1,
            failed: false,
            containerNameA: "meister-review-\(request.job.id.rawValue)-a",
            containerNameB: "meister-review-\(request.job.id.rawValue)-b",
            containerName: "meister-judge-\(request.job.id.rawValue)"
        )
    }
}

private func queuedJob() -> Job {
    let now = Date()
    return Job(
        id: JobID.generate(),
        createdAt: now,
        updatedAt: now,
        status: .queued,
        scope: .full,
        reviewerAModelID: "anthropic/claude-sonnet-4-5",
        reviewerBModelID: "openai/gpt-5.2",
        judgeModelID: "anthropic/claude-sonnet-4-5"
    )
}
