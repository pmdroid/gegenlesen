import Foundation

public struct PathGlob: Sendable, Equatable {
    public var patterns: [String]

    public init(_ patterns: [String]) {
        self.patterns = patterns
    }

    public static let defaultIgnorePatterns: [String] = [
        "node_modules/**",
        ".git/**",
        "dist/**",
        "build/**",
        ".build/**",
        "target/**",
        "var/**",
        "**/*.lock",
        "**/*.min.js",
        "**/*.min.css",
        "**/Package.resolved",
        "**/*.{png,jpg,jpeg,gif,webp,ico,svg,woff,woff2,ttf,otf,mp3,mp4,mov,pdf,zip,gz,tgz,wasm,o,a,so,dylib,class,jar}",
    ]

    public static let defaultIgnores = PathGlob(defaultIgnorePatterns)

    public func matches(_ path: String, isDirectory: Bool = false) -> Bool {
        lastMatch(path, isDirectory: isDirectory) == true
    }

    public func lastMatch(_ path: String, isDirectory: Bool = false) -> Bool? {
        let normalized = Self.normalize(path)
        var result: Bool?
        for raw in patterns {
            let negated = raw.hasPrefix("!")
            let body = negated ? String(raw.dropFirst()) : raw
            for candidate in Self.expandBraces(body) {
                if Self.pattern(candidate, matches: normalized, isDirectory: isDirectory) {
                    result = !negated
                }
            }
        }
        return result
    }

    public static func normalize(_ path: String) -> String {
        var raw = path.replacingOccurrences(of: "\\", with: "/")
        while raw.hasPrefix("./") {
            raw.removeFirst(2)
        }
        if raw.hasPrefix("/") {
            raw.removeFirst()
        }
        while raw.contains("//") {
            raw = raw.replacingOccurrences(of: "//", with: "/")
        }
        if raw.hasSuffix("/") {
            raw.removeLast()
        }
        return raw
    }

    public static func expandBraces(_ pattern: String) -> [String] {
        guard let open = firstBraceOpen(pattern) else { return [pattern] }
        guard let close = matchingBraceClose(pattern, open: open) else { return [pattern] }
        let prefix = String(pattern[..<open])
        let inner = String(pattern[pattern.index(after: open)..<close])
        let suffix = String(pattern[pattern.index(after: close)...])
        let alternatives = splitTopLevel(inner, separator: ",")
        guard alternatives.count > 1 else { return [pattern] }
        return alternatives.flatMap { expandBraces(prefix + $0 + suffix) }
    }

    static func pattern(_ glob: String, matches path: String, isDirectory: Bool) -> Bool {
        var glob = glob
        var directoryOnly = false
        if glob.hasSuffix("/") {
            directoryOnly = true
            glob.removeLast()
        }
        if glob.hasPrefix("/") {
            glob.removeFirst()
        }
        if glob.isEmpty {
            return path.isEmpty
        }
        let matchInAnyDir = !glob.contains("/")
        if directoryOnly {
            return directoryMatches(glob, path: path, isDirectory: isDirectory, anyDir: matchInAnyDir)
        }
        guard let regex = compile(glob, matchInAnyDir: matchInAnyDir) else {
            return false
        }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }

    private static func directoryMatches(
        _ glob: String,
        path: String,
        isDirectory: Bool,
        anyDir: Bool
    ) -> Bool {
        if path == glob {
            return isDirectory
        }
        if path.hasPrefix(glob + "/") {
            return true
        }
        guard anyDir else { return false }
        if path.hasSuffix("/" + glob) {
            return isDirectory
        }
        return path.contains("/" + glob + "/")
    }

    private static func compile(_ glob: String, matchInAnyDir: Bool) -> NSRegularExpression? {
        var body = ""
        let chars = Array(glob)
        var index = 0
        while index < chars.count {
            if chars[index] == "*", index + 1 < chars.count, chars[index + 1] == "*" {
                let afterStars = index + 2
                if afterStars < chars.count, chars[afterStars] == "/" {
                    body += "(?:.*/)?"
                    index = afterStars + 1
                } else {
                    body += ".*"
                    index = afterStars
                }
                continue
            }
            if chars[index] == "*" {
                body += "[^/]*"
                index += 1
                continue
            }
            if chars[index] == "?" {
                body += "[^/]"
                index += 1
                continue
            }
            body += NSRegularExpression.escapedPattern(for: String(chars[index]))
            index += 1
        }
        let prefix = matchInAnyDir ? "(?:.*/)?" : ""
        let pattern = "^\(prefix)\(body)$"
        return try? NSRegularExpression(pattern: pattern)
    }

    private static func firstBraceOpen(_ pattern: String) -> String.Index? {
        var escaped = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "{" {
                return index
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func matchingBraceClose(_ pattern: String, open: String.Index) -> String.Index? {
        var depth = 0
        var escaped = false
        var index = open
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "{" {
                depth += 1
                current.append(character)
            } else if character == "}" {
                depth -= 1
                current.append(character)
            } else if character == separator, depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }
}