import Foundation

public enum Normalize: Sendable {
    /// NFC, trim, collapse Unicode whitespace / newlines to a single ASCII space.
    public static func whitespace(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    public static func titleKey(_ title: String) -> String {
        whitespace(title).lowercased()
    }
}
