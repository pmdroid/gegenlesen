import Foundation

public struct AgentReviewRequest: Sendable {
    public var job: Job
    public var workspace: Workspace
    public var files: [JobFile]
    public var rules: [Rule]
    public var parentFindings: [Finding]
    public var newWork: Bool
    public var isCancelled: (@Sendable () async -> Bool)?

    public init(
        job: Job,
        workspace: Workspace,
        files: [JobFile],
        rules: [Rule],
        parentFindings: [Finding] = [],
        newWork: Bool,
        isCancelled: (@Sendable () async -> Bool)? = nil
    ) {
        self.job = job
        self.workspace = workspace
        self.files = files
        self.rules = rules
        self.parentFindings = parentFindings
        self.newWork = newWork
        self.isCancelled = isCancelled
    }
}

public struct AgentReviewResult: Sendable {
    public var findings: [Finding]
    public var validFileCount: Int
    public var failed: Bool
    public var errorMessage: String?
    public var containerNameA: String
    public var containerNameB: String
    public var containerName: String

    public init(
        findings: [Finding],
        validFileCount: Int,
        failed: Bool,
        errorMessage: String? = nil,
        containerNameA: String,
        containerNameB: String,
        containerName: String
    ) {
        self.findings = findings
        self.validFileCount = validFileCount
        self.failed = failed
        self.errorMessage = errorMessage
        self.containerNameA = containerNameA
        self.containerNameB = containerNameB
        self.containerName = containerName
    }
}

public protocol ReviewerRunning: Sendable {
    func run(_ request: AgentReviewRequest) async -> AgentReviewResult
}
