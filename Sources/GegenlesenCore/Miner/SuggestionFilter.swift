import Foundation

public enum SuggestionSignal: String, Sendable, Equatable {
    case endorse
    case reject
    case none
}

/// Job-level "would you have merged unread?" label. Miner context only.
/// Never used to auto-drop or auto-enable a finding.
public struct MergeIntentContext: Sendable, Equatable {
    public var wouldMerge: Bool
    public var weight: String
    public var riskVerdict: RiskVerdict
    public var safeUnread: Bool

    public init(wouldMerge: Bool, weight: String, riskVerdict: RiskVerdict, safeUnread: Bool) {
        self.wouldMerge = wouldMerge
        self.weight = weight
        self.riskVerdict = riskVerdict
        self.safeUnread = safeUnread
    }

    public static func from(_ risk: RiskAssessment?) -> MergeIntentContext? {
        guard let risk, let safe = risk.safeUnread else { return nil }
        let highest = !safe && risk.verdict == .autoApprove
        return MergeIntentContext(
            wouldMerge: safe,
            weight: highest ? "highest" : "normal",
            riskVerdict: risk.verdict,
            safeUnread: safe
        )
    }

    public var jsonObject: [String: Any] {
        [
            "safe_unread": safeUnread,
            "would_merge": wouldMerge,
            "weight": weight,
            "risk_verdict": riskVerdict.rawValue,
        ]
    }
}

public enum SuggestionFilter: Sendable {
    public static func signal(
        for finding: Finding,
        feedback: [FindingFeedback]
    ) -> SuggestionSignal {
        let latest = feedback
            .filter { $0.findingID == finding.id && $0.verdict.isCurrentVerdict }
            .max(by: { $0.ts < $1.ts })
        switch latest?.verdict {
        case .agree, .shouldBeRule:
            return .endorse
        case .disagree:
            return .reject
        default:
            // Unendorsed judge-drops stay out of learn. A later agree / should_be_rule
            // endorses eligibility only — it does not resurrect the finding in the job list.
            if finding.judgeVerdict == .drop {
                return .reject
            }
            return .none
        }
    }

    public static func matchingFinding(title: String, in findings: [Finding]) -> Finding? {
        let needle = Normalize.titleKey(title)
        return findings.first { Normalize.titleKey($0.title) == needle }
    }

    /// Job-sourced one-off findings stay out of the inbox unless a human endorsed them,
    /// or the operator said they would not have merged and this finding is a kept error.
    /// Agree / should_be_rule on a judge-dropped finding is learn eligibility only.
    /// The job-level merge-intent label never auto-suppresses a finding.
    /// Novel miner titles (no matching finding) stay as judge candidates.
    public static func keepJobRule(
        draft: MinedRuleDraft,
        findings: [Finding],
        feedback: [FindingFeedback],
        risk: RiskAssessment? = nil
    ) -> Bool {
        guard let finding = matchingFinding(title: draft.title, in: findings) else {
            return true
        }
        switch signal(for: finding, feedback: feedback) {
        case .endorse:
            return true
        case .reject:
            return false
        case .none:
            guard let intent = MergeIntentContext.from(risk), !intent.wouldMerge else {
                return false
            }
            return isKeptError(finding)
        }
    }

    public static func isKeptError(_ finding: Finding) -> Bool {
        if finding.lifecycle == .resolved { return false }
        if finding.judgeVerdict == .drop || finding.judgeVerdict == .unavailable {
            return false
        }
        return (finding.judgeSeverity ?? finding.severity) == .error
    }

    /// Wire object for `job/feedback.json`. Nil when there is nothing to stage.
    public static func stagedFeedbackJSON(
        findingFeedback: [[String: String]],
        risk: RiskAssessment?
    ) -> [String: Any]? {
        let intent = MergeIntentContext.from(risk)
        if findingFeedback.isEmpty, intent == nil { return nil }
        var object: [String: Any] = ["finding_feedback": findingFeedback]
        if let intent {
            object["merge_intent"] = intent.jsonObject
        }
        return object
    }

    public static func endorsedFindings(
        _ findings: [Finding],
        feedback: [FindingFeedback]
    ) -> [Finding] {
        findings.filter { signal(for: $0, feedback: feedback) == .endorse }
    }

    public static func contextBody(
        findings: [Finding],
        feedback: [FindingFeedback]
    ) -> String? {
        let endorsed = endorsedFindings(findings, feedback: feedback)
        guard !endorsed.isEmpty else { return nil }
        return endorsed.map { "- \($0.title): \($0.message)" }.joined(separator: "\n")
    }
}
