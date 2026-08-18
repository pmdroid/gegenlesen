import Foundation

public enum Normalize: Sendable {
    /// NFC, trim, then collapse `\p{Z}` / `\n` / `\r` / `\t` runs to one ASCII space.
    public static func whitespace(_ s: String) -> String {
        let nfc = s.precomposedStringWithCanonicalMapping
        var collapsed = String()
        collapsed.reserveCapacity(nfc.count)
        var inRun = false
        for scalar in nfc.unicodeScalars {
            if isCollapsedWhitespace(scalar) {
                inRun = true
                continue
            }
            if inRun {
                if !collapsed.isEmpty {
                    collapsed.unicodeScalars.append(" ")
                }
                inRun = false
            }
            collapsed.unicodeScalars.append(scalar)
        }
        return collapsed
    }

    private static func isCollapsedWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\r" || scalar == "\t" {
            return true
        }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }
}

public enum Fingerprint: Sendable {
    public static func normalizeWhitespace(_ text: String) -> String {
        Normalize.whitespace(text)
    }

    public static func sha256(ruleID: RuleID?, path: String, snippet: String) -> String {
        let payload = (ruleID?.rawValue ?? "") + "\n" + path + "\n" + Normalize.whitespace(snippet)
        return ContentHash.sha256(Data(payload.utf8))
    }
}
