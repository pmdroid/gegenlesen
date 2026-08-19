import Foundation

public enum SuggestionSignal: String, Sendable, Equatable {
    case endorse
    case reject
    case none
}

public enum SuggestionFilter: Sendable {
    public static func signal(
        for finding: Finding,
        feedback: [FindingFeedback]
    ) -> SuggestionSignal {
        if finding.judgeVerdict == .drop {
            return .reject
        }
        let latest = feedback
            .filter { $0.findingID == finding.id && $0.verdict.isCurrentVerdict }
            .max(by: { $0.ts < $1.ts })
        switch latest?.verdict {
        case .agree, .shouldBeRule:
            return .endorse
        case .disagree:
            return .reject
        default:
            return .none
        }
    }

    public static func matchingFinding(title: String, in findings: [Finding]) -> Finding? {
        let needle = Normalize.titleKey(title)
        return findings.first { Normalize.titleKey($0.title) == needle }
    }

    /// Job-sourced one-off findings stay out of the inbox unless a human endorsed them.
    /// Novel miner titles (no matching finding) stay as judge candidates.
    public static func keepJobRule(
        draft: MinedRuleDraft,
        findings: [Finding],
        feedback: [FindingFeedback]
    ) -> Bool {
        guard let finding = matchingFinding(title: draft.title, in: findings) else {
            return true
        }
        return signal(for: finding, feedback: feedback) == .endorse
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
