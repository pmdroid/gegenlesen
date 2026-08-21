import Foundation
import GegenlesenCore

/// Drops planted eval/fixture paths and obvious fake credential literals
/// from scanner secret hits. Gitleaks findings skip the judge, so noise
/// has to die here.
enum SecretNoiseFilter: Sendable {
    static let plantedGlobs = PathGlob([
        "evals/cases/**",
        "**/testdata/**",
        "**/fixtures/**",
        "**/mocks/**",
        "**/__mocks__/**",
        "**/snapshots/**",
        "examples/**",
        "**/examples/**",
        "**/example/**",
        "**/*.snap",
    ])

    static func shouldDrop(ruleID: RuleID, filePath: String, match: String) -> Bool {
        guard ruleID.rawValue.hasPrefix("scanner-") else { return false }
        if plantedGlobs.matches(filePath) { return true }
        if ruleID.rawValue == "scanner-gitleaks",
           let value = credentialLiteral(in: match),
           isPlaceholder(value)
        {
            return true
        }
        return false
    }

    static func credentialLiteral(in match: String) -> String? {
        if let open = match.firstIndex(where: { $0 == "\"" || $0 == "'" }) {
            let mark = match[open]
            let after = match.index(after: open)
            let raw: Substring
            if let close = match[after...].firstIndex(of: mark) {
                raw = match[after..<close]
            } else {
                raw = match[after...].prefix { ch in
                    ch.isLetter || ch.isNumber || ch == "_" || ch == "-"
                }
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 16 { return trimmed }
        }
        if let sep = match.lastIndex(where: { $0 == "=" || $0 == ":" }) {
            let after = match.index(after: sep)
            let raw = match[after...]
                .drop(while: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
                .prefix { ch in
                    ch.isLetter || ch.isNumber || ch == "_" || ch == "-"
                }
            if raw.count >= 16 { return String(raw) }
        }
        let bare = match.trimmingCharacters(in: .whitespacesAndNewlines)
        if bare.count >= 16,
           bare.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        {
            return bare
        }
        return nil
    }

    static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return true }
        let lower = trimmed.lowercased()
        let unique = Set(lower)
        if unique.count <= 4 { return true }
        if Double(unique.count) / Double(lower.count) < 0.25 { return true }
        if value.allSatisfy({ $0.isLowercase || $0 == "_" || $0 == "-" }), value.contains("_") {
            return true
        }
        if hasLongSequentialRun(lower) { return true }
        if isKeyboardWalk(lower) { return true }
        if placeholderNeedles.contains(where: { lower.contains($0) }) { return true }
        return false
    }

    private static let placeholderNeedles: [String] = [
        "abcdefghijklmnopqrstuvwxyz",
        "zyxwvutsrqponmlkjihgfedcba",
        "0123456789abcdef",
        "placeholder",
        "changeme",
        "your-api-key",
        "your_api_key",
        "yourapikey",
        "dummysecret",
        "dummy_secret",
        "fakesecret",
        "fake_secret",
        "examplekey",
        "example_key",
        "example-key",
        "not-a-secret",
        "notasecret",
        "replaceme",
        "redacted",
        "insert-key",
        "insert_key",
        "loremipsum",
        "testtoken",
        "test_token",
        "test-token",
        "sampletoken",
        "passwordpassword",
        "secretsecret",
        "xxxxxxxx",
    ]

    private static func hasLongSequentialRun(_ lower: String) -> Bool {
        let codes = lower.unicodeScalars.map { Int($0.value) }
        guard codes.count >= 10 else { return false }
        func run(step: Int) -> Bool {
            var length = 1
            for index in 1..<codes.count {
                if codes[index] == codes[index - 1] + step {
                    length += 1
                    if length >= 10 { return true }
                } else {
                    length = 1
                }
            }
            return false
        }
        return run(step: 1) || run(step: -1)
    }

    private static func isKeyboardWalk(_ lower: String) -> Bool {
        let rows = [
            "abcdefghijklmnopqrstuvwxyz",
            "qwertyuiopasdfghjklzxcvbnm",
            "0123456789",
        ]
        return rows.contains { row in
            lower.count >= 10 && row.contains(lower)
        }
    }
}
