import Foundation

public struct Finding: Sendable, Equatable {
    public var id: FindingID
    public var jobID: JobID
    public var ruleID: RuleID?
    public var phase: FindingPhase
    public var reviewerSlot: ReviewerSlot?
    public var severity: Severity
    public var title: String
    public var message: String
    public var filePath: String?
    public var startLine: Int?
    public var endLine: Int?
    public var snippet: String?
    public var agentRationale: String?
    public var judgeVerdict: JudgeVerdict?
    public var judgeSeverity: Severity?
    public var judgeRationale: String?
    public var confidence: Double?
    public var lifecycle: FindingLifecycle
    public var parentFindingID: FindingID?
    public var suggestedPatch: String?
    public var fingerprint: String?
    public var evidenceOK: Bool?
    public var createdAt: Date

    public init(
        id: FindingID,
        jobID: JobID,
        ruleID: RuleID? = nil,
        phase: FindingPhase,
        reviewerSlot: ReviewerSlot? = nil,
        severity: Severity,
        title: String,
        message: String,
        filePath: String? = nil,
        startLine: Int? = nil,
        endLine: Int? = nil,
        snippet: String? = nil,
        agentRationale: String? = nil,
        judgeVerdict: JudgeVerdict? = nil,
        judgeSeverity: Severity? = nil,
        judgeRationale: String? = nil,
        confidence: Double? = nil,
        lifecycle: FindingLifecycle = .new,
        parentFindingID: FindingID? = nil,
        suggestedPatch: String? = nil,
        fingerprint: String? = nil,
        evidenceOK: Bool? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.jobID = jobID
        self.ruleID = ruleID
        self.phase = phase
        self.reviewerSlot = reviewerSlot
        self.severity = severity
        self.title = title
        self.message = message
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.snippet = snippet
        self.agentRationale = agentRationale
        self.judgeVerdict = judgeVerdict
        self.judgeSeverity = judgeSeverity
        self.judgeRationale = judgeRationale
        self.confidence = confidence
        self.lifecycle = lifecycle
        self.parentFindingID = parentFindingID
        self.suggestedPatch = suggestedPatch
        self.fingerprint = fingerprint
        self.evidenceOK = evidenceOK
        self.createdAt = createdAt
    }
}
