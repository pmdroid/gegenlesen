import Foundation

public enum RetrievalQuery: Sendable {
    public static func tokens(paths: [String], patch: Data?, title: String?) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        func add(_ raw: String) {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.count >= 2 else { return }
            let key = token.lowercased()
            if seen.insert(key).inserted {
                ordered.append(token)
            }
        }

        for path in paths {
            let name = (path as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            add(stem)
            add(name)
        }
        if let title {
            for piece in title.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }) {
                add(String(piece))
            }
        }
        if let patch, let text = String(data: patch, encoding: .utf8) {
            for symbol in symbols(in: text) {
                add(symbol)
            }
        }
        return ordered
    }

    public static func ftsQuery(tokens: [String]) -> String {
        tokens
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { $0.count >= 2 }
            .prefix(32)
            .map { "\"\($0)\"" }
            .joined(separator: " OR ")
    }

    public static func symbols(in patch: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]{1,63}")
        var found: [String] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("---") || line.hasPrefix("+++") || line.hasPrefix("diff ")
                || line.hasPrefix("index ") || line.hasPrefix("@@") {
                continue
            }
            let body: Substring
            if line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" ") {
                body = line.dropFirst()
            } else {
                body = Substring(line)
            }
            let text = String(body)
            guard let pattern else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            pattern.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let swift = Range(match.range, in: text) else { return }
                found.append(String(text[swift]))
            }
        }
        return found
    }
}
