import Foundation

public enum OperatorSuppression: Sendable {
    public static let dropReason = "operator_disagree"

    public static func fingerprint(for finding: Finding) -> String {
        if let value = finding.fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return Fingerprint.sha256(
            ruleID: finding.ruleID,
            path: finding.filePath ?? "",
            snippet: finding.snippet ?? ""
        )
    }

    public static func apply(_ finding: Finding, suppressed: Set<String>) -> Finding {
        guard suppressed.contains(fingerprint(for: finding)) else { return finding }
        var next = finding
        next.judgeVerdict = .drop
        next.judgeRationale = dropReason
        return next
    }
}
