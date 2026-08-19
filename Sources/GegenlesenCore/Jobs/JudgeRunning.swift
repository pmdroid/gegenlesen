import Foundation

public struct JudgeRequest: Sendable {
    public var job: Job
    public var workspace: Workspace
    public var isCancelled: (@Sendable () async -> Bool)?

    public init(
        job: Job,
        workspace: Workspace,
        isCancelled: (@Sendable () async -> Bool)? = nil
    ) {
        self.job = job
        self.workspace = workspace
        self.isCancelled = isCancelled
    }
}

public struct JudgeRunResult: Sendable {
    public var outcome: JudgeOutcome
    public var transcript: Data
    public var containerName: String

    public init(outcome: JudgeOutcome, transcript: Data = Data(), containerName: String) {
        self.outcome = outcome
        self.transcript = transcript
        self.containerName = containerName
    }
}

public protocol JudgeRunning: Sendable {
    func run(_ request: JudgeRequest) async -> JudgeRunResult
}
