import Foundation

public struct WorkspaceGCJob: Sendable {
    public var store: Store
    public var now: Date
    public var workspaceAge: TimeInterval
    public var archiveAge: TimeInterval
    public var transcriptAge: TimeInterval

    public init(
        store: Store,
        now: Date = Date(),
        workspaceAge: TimeInterval = 24 * 60 * 60,
        archiveAge: TimeInterval = 7 * 24 * 60 * 60,
        transcriptAge: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.store = store
        self.now = now
        self.workspaceAge = workspaceAge
        self.archiveAge = archiveAge
        self.transcriptAge = transcriptAge
    }

    public func run() async throws {
        let jobs = try await store.terminalJobs()
        let fm = FileManager.default
        for job in jobs {
            guard let finished = job.finishedAt else { continue }
            let age = now.timeIntervalSince(finished)
            let id = job.id.rawValue
            if age >= workspaceAge {
                try? fm.removeItem(at: store.blobs.workspaceURL(jobID: id))
            }
            if age >= archiveAge {
                try? fm.removeItem(at: store.blobs.archiveURL(jobID: id))
                try? fm.removeItem(at: store.blobs.identifyMetaURL(jobID: id))
                try? fm.removeItem(at: store.blobs.patchURL(jobID: id))
            }
            if age >= transcriptAge {
                for phase in ["review", "review_a", "review_b", "judge", "mine", "suggestion_judge"] {
                    try? fm.removeItem(at: store.blobs.transcriptURL(jobID: id, phase: phase))
                }
                try? fm.removeItem(at: store.blobs.findingsURL(jobID: id, stage: "agent"))
                try? fm.removeItem(at: store.blobs.findingsURL(jobID: id, stage: "pre-judge"))
                try? fm.removeItem(at: store.blobs.findingsURL(jobID: id, stage: "post-judge"))
            }
        }
    }
}
