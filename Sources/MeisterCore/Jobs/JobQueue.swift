public protocol ReviewJobQueuing: Sendable {
    func pushReview(_ id: JobID) async throws
    func cancel(_ id: JobID) async
}

public struct NoopJobQueue: ReviewJobQueuing {
    public init() {}

    public func pushReview(_ id: JobID) async throws {}
    public func cancel(_ id: JobID) async {}
}

public actor RecordingJobQueue: ReviewJobQueuing {
    public private(set) var pushed: [JobID] = []
    public private(set) var cancelled: [JobID] = []

    public init() {}

    public func pushReview(_ id: JobID) async throws {
        pushed.append(id)
    }

    public func cancel(_ id: JobID) async {
        cancelled.append(id)
    }
}
