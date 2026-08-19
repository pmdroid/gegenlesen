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

    public static func titleKey(_ title: String) -> String {
        whitespace(title).lowercased()
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
