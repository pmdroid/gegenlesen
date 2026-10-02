import Foundation

public struct ReviewDeadlineExceeded: Error, Sendable, CustomStringConvertible {
    public init() {}
    public var description: String { "review_deadline_exceeded" }
}

public enum ReviewDeadline {
    public static let maximumSeconds: TimeInterval = 300
    @TaskLocal public static var expiresAt: ContinuousClock.Instant?

    public static func check() throws {
        try Task.checkCancellation()
        if let expiresAt, ContinuousClock.now >= expiresAt {
            throw ReviewDeadlineExceeded()
        }
    }

    public static func timeout(_ requested: Duration, reserving reserve: Duration = .zero) -> Duration {
        guard let expiresAt else { return requested }
        let remaining = max(.zero, expiresAt - ContinuousClock.now)
        return max(.zero, min(requested, remaining - min(reserve, remaining / 2)))
    }

    public static func run<T: Sendable>(
        timeout requested: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try check()
        let deadline = ContinuousClock.now + timeout(requested)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                throw ReviewDeadlineExceeded()
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            if ContinuousClock.now >= deadline { throw ReviewDeadlineExceeded() }
            return result
        }
    }
}
