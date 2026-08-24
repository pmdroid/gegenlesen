import Foundation

public struct LearnSweepJob: Sendable {
    public var store: Store
    public var intervalMinutes: Int
    public var now: Date
    public var enqueue: @Sendable (JobID) async throws -> Void

    public init(
        store: Store,
        intervalMinutes: Int,
        now: Date = Date(),
        enqueue: @escaping @Sendable (JobID) async throws -> Void
    ) {
        self.store = store
        self.intervalMinutes = intervalMinutes
        self.now = now
        self.enqueue = enqueue
    }

    public func run() async throws {
        guard intervalMinutes > 0 else { return }
        if try await store.hasActiveJobs() { return }
        if try await store.learnedWithin(minutes: intervalMinutes, now: now) { return }
        let jobIDs = try await store.jobsNeedingLearn()
        for jobID in jobIDs {
            try await enqueue(jobID)
        }
    }
}
