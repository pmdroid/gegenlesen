import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct LearnSweepJobTests {
    @Test
    func skipsWhenIntervalIsZero() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let box = EnqueueBox()
            try await LearnSweepJob(store: store, intervalMinutes: 0) { id in
                await box.record(id)
            }.run()
            #expect(await box.ids.isEmpty)
        }
    }

    @Test
    func enqueuesSucceededJobWithNewFeedback() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            let job = sampleJob(id: "job-learn-1", status: .succeeded, finishedAt: now)
            try await store.insertJob(job)
            let inserted = try await store.insertFindings(
                [
                    FindingDraft(
                        ruleID: nil,
                        phase: .agent,
                        severity: .warning,
                        title: "silent hop",
                        message: "log it",
                        filePath: "Sources/A.swift",
                        startLine: 1,
                        endLine: 1,
                        snippet: "catch { }"
                    ),
                ],
                jobID: job.id,
                now: now
            )
            _ = try await store.applyFindingFeedback(
                finding: inserted[0],
                verdict: .agree,
                reaction: .thumbsUp,
                comment: nil,
                now: now
            )

            let box = EnqueueBox()
            try await LearnSweepJob(store: store, intervalMinutes: 15, now: now) { id in
                await box.record(id)
            }.run()
            #expect(await box.ids == [job.id])
        }
    }

    @Test
    func skipsWhenAReviewIsActive() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            let done = sampleJob(id: "job-done", status: .succeeded, finishedAt: now)
            try await store.insertJob(done)
            let inserted = try await store.insertFindings(
                [
                    FindingDraft(
                        ruleID: nil,
                        phase: .agent,
                        severity: .warning,
                        title: "t",
                        message: "m",
                        filePath: "A.swift",
                        startLine: 1,
                        endLine: 1,
                        snippet: "x"
                    ),
                ],
                jobID: done.id,
                now: now
            )
            _ = try await store.applyFindingFeedback(
                finding: inserted[0],
                verdict: .agree,
                reaction: .thumbsUp,
                comment: nil,
                now: now
            )
            try await store.insertJob(sampleJob(id: "job-active", status: .reviewing, startedAt: now))

            let box = EnqueueBox()
            try await LearnSweepJob(store: store, intervalMinutes: 15, now: now) { id in
                await box.record(id)
            }.run()
            #expect(await box.ids.isEmpty)
        }
    }

    @Test
    func skipsWhenAlreadyLearnedAfterFeedback() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let feedbackAt = Date(timeIntervalSince1970: 1_000)
            let learnedAt = Date(timeIntervalSince1970: 2_000)
            let job = sampleJob(id: "job-learned", status: .succeeded, finishedAt: feedbackAt)
            try await store.insertJob(job)
            let inserted = try await store.insertFindings(
                [
                    FindingDraft(
                        ruleID: nil,
                        phase: .agent,
                        severity: .warning,
                        title: "t",
                        message: "m",
                        filePath: "A.swift",
                        startLine: 1,
                        endLine: 1,
                        snippet: "x"
                    ),
                ],
                jobID: job.id,
                now: feedbackAt
            )
            _ = try await store.applyFindingFeedback(
                finding: inserted[0],
                verdict: .comment,
                reaction: nil,
                comment: "keep this",
                now: feedbackAt
            )
            var learn = sampleJob(id: "learn-child", status: .succeeded, finishedAt: learnedAt)
            learn.parentJobID = job.id
            learn.title = "learn hop"
            learn.createdAt = learnedAt
            learn.updatedAt = learnedAt
            try await store.insertJob(learn)

            let box = EnqueueBox()
            let later = Date(timeIntervalSince1970: 10_000)
            try await LearnSweepJob(store: store, intervalMinutes: 15, now: later) { id in
                await box.record(id)
            }.run()
            #expect(await box.ids.isEmpty)
        }
    }
}

private actor EnqueueBox {
    var ids: [JobID] = []

    func record(_ id: JobID) {
        ids.append(id)
    }
}
