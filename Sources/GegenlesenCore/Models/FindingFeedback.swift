import Foundation

public struct FindingFeedback: Sendable, Equatable {
    public var id: Int
    public var findingID: FindingID
    public var jobID: JobID
    public var ts: Date
    public var verdict: FeedbackVerdict
    public var reaction: FeedbackReaction?
    public var comment: String?
    public var suggestedRuleID: RuleID?

    public init(
        id: Int,
        findingID: FindingID,
        jobID: JobID,
        ts: Date,
        verdict: FeedbackVerdict,
        reaction: FeedbackReaction? = nil,
        comment: String? = nil,
        suggestedRuleID: RuleID? = nil
    ) {
        self.id = id
        self.findingID = findingID
        self.jobID = jobID
        self.ts = ts
        self.verdict = verdict
        self.reaction = reaction
        self.comment = comment
        self.suggestedRuleID = suggestedRuleID
    }
}
