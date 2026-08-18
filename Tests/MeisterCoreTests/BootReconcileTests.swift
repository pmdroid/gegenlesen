import Foundation
import Testing
@testable import MeisterCore

@Suite
struct BootReconcileTests {
    @Test
    func failsInFlightAndRequeuesFreshQueued() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            let reviewing = sampleJob(
                id: "11111111-1111-4111-8111-111111111111",
                status: .reviewing,
                startedAt: now
            )
            let queuedStarted = sampleJob(
                id: "22222222-2222-4222-8222-222222222222",
                status: .queued,
                startedAt: now
            )
            let queuedFresh = sampleJob(
                id: "33333333-3333-4333-8333-333333333333",
                status: .queued
            )
            let succeeded = sampleJob(
                id: "44444444-4444-4444-8444-444444444444",
                status: .succeeded,
                finishedAt: now
            )
            try await store.insertJob(reviewing)
            try await store.insertJob(queuedStarted)
            try await store.insertJob(queuedFresh)
            try await store.insertJob(succeeded)

            let docker = RecordingDocker()
            let queue = RecordingJobQueue()
            await BootReconcile().run(store: store, docker: docker, jobs: queue)

            let prefixes = await docker.removedPrefixes
            #expect(prefixes == ["meister-"])

            let failedReview = try await store.job(id: reviewing.id)
            #expect(failedReview?.status == .failed)
            #expect(failedReview?.errorMessage == "process_restarted")

            let failedQueued = try await store.job(id: queuedStarted.id)
            #expect(failedQueued?.status == .failed)
            #expect(failedQueued?.errorMessage == "process_restarted")

            let stillQueued = try await store.job(id: queuedFresh.id)
            #expect(stillQueued?.status == .queued)

            let stillSucceeded = try await store.job(id: succeeded.id)
            #expect(stillSucceeded?.status == .succeeded)

            let pushed = await queue.pushed
            #expect(pushed == [queuedFresh.id])
        }
    }
}

@Suite
struct WorkspaceGCJobTests {
    @Test
    func deletesAgedWorkspaceArchiveAndTranscripts() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try store.blobs.ensureLayout()
            let now = Date()
            let old = now.addingTimeInterval(-40 * 24 * 60 * 60)
            let job = sampleJob(
                id: "55555555-5555-4555-8555-555555555555",
                status: .succeeded,
                finishedAt: old
            )
            try await store.insertJob(job)

            let workspace = store.blobs.workspaceURL(jobID: job.id.rawValue)
            let archive = store.blobs.archiveURL(jobID: job.id.rawValue)
            let transcript = store.blobs.transcriptURL(jobID: job.id.rawValue, phase: "review")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try Data("tar".utf8).write(to: archive)
            try Data("log".utf8).write(to: transcript)

            try await WorkspaceGCJob(store: store, now: now).run()

            #expect(!FileManager.default.fileExists(atPath: workspace.path))
            #expect(!FileManager.default.fileExists(atPath: archive.path))
            #expect(!FileManager.default.fileExists(atPath: transcript.path))
        }
    }

    @Test
    func keepsRecentWorkspace() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try store.blobs.ensureLayout()
            let now = Date()
            let job = sampleJob(
                id: "66666666-6666-4666-8666-666666666666",
                status: .succeeded,
                finishedAt: now.addingTimeInterval(-60)
            )
            try await store.insertJob(job)
            let workspace = store.blobs.workspaceURL(jobID: job.id.rawValue)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try await WorkspaceGCJob(store: store, now: now).run()
            #expect(FileManager.default.fileExists(atPath: workspace.path))
        }
    }
}

func sampleJob(
    id: String,
    status: JobStatus,
    startedAt: Date? = nil,
    finishedAt: Date? = nil
) -> Job {
    let now = Date()
    return Job(
        id: JobID(id),
        createdAt: now,
        updatedAt: now,
        startedAt: startedAt,
        finishedAt: finishedAt,
        status: status,
        scope: .full,
        reviewerAModelID: "a",
        reviewerBModelID: "b",
        judgeModelID: "j"
    )
}
