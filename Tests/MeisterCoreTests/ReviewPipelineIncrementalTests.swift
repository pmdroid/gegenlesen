import Foundation
import Testing
@testable import MeisterCore

@Suite
struct ReviewPipelineIncrementalTests {
    @Test
    func emptyInterdiffSucceedsWithoutReviewer() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let parent = try await insertSucceededParent(store: store, archive: archive)
                let child = queuedJob(scope: .incremental, parent: parent.id)
                try await store.insertJob(child)
                try FileManager.default.copyItem(
                    at: archive,
                    to: store.blobs.archiveURL(jobID: child.id.rawValue)
                )
                let reviewer = RecordingReviewer()
                let pipeline = ReviewPipeline(
                    store: store,
                    skipAgent: false,
                    reviewer: reviewer
                )
                try await pipeline.run(jobID: child.id)
                let after = try #require(try await store.job(id: child.id))
                #expect(after.status == .succeeded)
                #expect(after.containerNameA == nil)
                #expect(reviewer.called == false)
                let events = try await store.events(jobID: child.id)
                #expect(events.contains { $0.message == "interdiff_empty" })
                let findings = try await store.findings(jobID: child.id)
                #expect(findings.contains { $0.lifecycle == .stillOpen })
                let summary = try await store.summary(jobID: child.id)
                #expect(summary.stillOpen >= 1)
            }
        }
    }
}

private final class RecordingReviewer: ReviewerRunning, @unchecked Sendable {
    var called = false

    func run(_ request: AgentReviewRequest) async -> AgentReviewResult {
        called = true
        return AgentReviewResult(
            findings: [],
            validFileCount: 0,
            failed: request.newWork,
            errorMessage: request.newWork ? "reviewer_should_not_run" : nil,
            containerNameA: ReviewContainers.slot(request.job.id, .modelA),
            containerNameB: ReviewContainers.slot(request.job.id, .modelB),
            containerName: ReviewContainers.judge(request.job.id)
        )
    }
}

private func insertSucceededParent(store: Store, archive: URL) async throws -> Job {
    let now = Date()
    let parent = Job(
        id: JobID.generate(),
        createdAt: now,
        updatedAt: now,
        finishedAt: now,
        status: .succeeded,
        scope: .full,
        reviewerAModelID: "a",
        reviewerBModelID: "b",
        judgeModelID: "j",
        baseSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        headSHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        fileCount: 1
    )
    try await store.insertJob(parent)
    let sha = ContentHash.sha256(Data("print(2)\n".utf8))
    try await store.replaceJobFiles([
        JobFile(
            jobID: parent.id,
            path: "Sources/A.swift",
            sha256: sha,
            status: .added,
            language: .swift
        ),
    ])
    let finding = Finding(
        id: FindingID.generate(),
        jobID: parent.id,
        ruleID: RuleID("use-project-logger"),
        phase: .agent,
        severity: .warning,
        title: "Use the project logger",
        message: "print is never OK",
        filePath: "Sources/A.swift",
        startLine: 1,
        endLine: 1,
        snippet: "print(2)",
        lifecycle: .new,
        createdAt: now
    )
    try await store.insertParsedFindings([finding])
    return parent
}

private func queuedJob(scope: JobScope = .full, parent: JobID? = nil) -> Job {
    let now = Date()
    return Job(
        id: JobID.generate(),
        createdAt: now,
        updatedAt: now,
        status: .queued,
        scope: scope,
        parentJobID: parent,
        reviewerAModelID: "anthropic/claude-sonnet-4-5",
        reviewerBModelID: "openai/gpt-5.2",
        judgeModelID: "anthropic/claude-sonnet-4-5"
    )
}

private func withPackedRepo(dir: URL, _ body: (URL) async throws -> Void) async throws {
    try await withTempDir("pipe-inc-pack") { repo in
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
        try writeFile(".meister/base_sha", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", in: repo)
        try writeFile(".meister/head_sha", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", in: repo)
        let archive = dir.appendingPathComponent("change-\(UUID().uuidString).tar.gz")
        try gzipTarCreate(from: repo, to: archive)
        try await body(archive)
    }
}
