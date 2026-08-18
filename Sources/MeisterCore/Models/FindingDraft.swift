import Foundation

public struct FindingDraft: Sendable, Equatable {
    public var ruleID: RuleID?
    public var phase: FindingPhase
    public var severity: Severity
    public var title: String
    public var message: String
    public var filePath: String
    public var startLine: Int
    public var endLine: Int
    public var snippet: String
    public var rationale: String?
    public var confidence: Double?
    public var suggestedPatch: String?

    public init(
        ruleID: RuleID? = nil,
        phase: FindingPhase = .deterministic,
        severity: Severity,
        title: String,
        message: String,
        filePath: String,
        startLine: Int,
        endLine: Int,
        snippet: String,
        rationale: String? = nil,
        confidence: Double? = nil,
        suggestedPatch: String? = nil
    ) {
        self.ruleID = ruleID
        self.phase = phase
        self.severity = severity
        self.title = title
        self.message = message
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.snippet = snippet
        self.rationale = rationale
        self.confidence = confidence
        self.suggestedPatch = suggestedPatch
    }
}

public struct DeterministicRunResult: Sendable, Equatable {
    public var drafts: [FindingDraft]
    public var timedOut: Bool

    public init(drafts: [FindingDraft], timedOut: Bool) {
        self.drafts = drafts
        self.timedOut = timedOut
    }
}

public protocol DeterministicRunning: Sendable {
    func run(
        files: [JobFile],
        workspace: Workspace,
        rules: [Rule],
        timeout: Duration
    ) async -> DeterministicRunResult
}