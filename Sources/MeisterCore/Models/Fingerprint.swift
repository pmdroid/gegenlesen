import Foundation

public enum Fingerprint: Sendable {
    public static func normalizeWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func sha256(ruleID: RuleID?, path: String, snippet: String) -> String {
        let payload = (ruleID?.rawValue ?? "") + "\n" + path + "\n" + normalizeWhitespace(snippet)
        return ContentHash.sha256(Data(payload.utf8))
    }
}
