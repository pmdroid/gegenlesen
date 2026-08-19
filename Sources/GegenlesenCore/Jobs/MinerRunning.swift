import Foundation

public struct MinerRunResult: Sendable {
    public var containerName: String
    public var failed: Bool
    public var errorMessage: String?

    public init(containerName: String, failed: Bool, errorMessage: String? = nil) {
        self.containerName = containerName
        self.failed = failed
        self.errorMessage = errorMessage
    }
}

public protocol MinerRunning: Sendable {
    func runMiner(
        jobID: JobID,
        workspace: Workspace,
        model: String,
        isCancelled: (@Sendable () async -> Bool)?
    ) async -> MinerRunResult
}
