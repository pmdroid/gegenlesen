import Foundation
import MeisterCore

public struct RegexChecker: DeterministicChecker {
    public init(rule: Rule) throws {
        guard case .regex(let pattern, let flags, _) = rule.payload else {
            throw CheckerSkip()
        }
        _ = try Regex(Self.apply(flags: flags, to: pattern))
    }

    public func check(file: JobFile, bytes: Data, workspace: Workspace, rule: Rule) throws -> [FindingDraft] {
        guard case .regex(let pattern, let flags, let message) = rule.payload else { return [] }
        let regex = try Regex(Self.apply(flags: flags, to: pattern))
        let text = String(decoding: bytes, as: UTF8.self)
        var drafts: [FindingDraft] = []
        for match in text.matches(of: regex) {
            let start = lineNumber(of: match.range.lowerBound, in: text)
            let end = lineNumber(of: match.range.upperBound, in: text)
            let snippet = lineSlice(in: text, start: start, end: end)
            drafts.append(
                FindingDraft(
                    ruleID: rule.id,
                    phase: .deterministic,
                    severity: rule.severity,
                    title: rule.title,
                    message: message,
                    filePath: file.path,
                    startLine: start,
                    endLine: max(end, start),
                    snippet: snippet
                )
            )
        }
        return drafts
    }

    static func apply(flags: String?, to pattern: String) -> String {
        guard let flags, !flags.isEmpty else { return pattern }
        var prefix = "(?"
        if flags.contains("i") { prefix.append("i") }
        if flags.contains("m") { prefix.append("m") }
        if flags.contains("s") { prefix.append("s") }
        if prefix == "(?" { return pattern }
        return prefix + ")" + pattern
    }
}

func lineNumber(of index: String.Index, in text: String) -> Int {
    var line = 1
    var cursor = text.startIndex
    while cursor < index, cursor < text.endIndex {
        if text[cursor] == "\n" {
            line += 1
        }
        cursor = text.index(after: cursor)
    }
    return line
}

func lineSlice(in text: String, start: Int, end: Int, maxBytes: Int = 4096) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let lo = max(start - 1, 0)
    let hi = min(max(end, start), lines.count)
    guard lo < lines.count else { return "" }
    let slice = lines[lo..<hi].joined(separator: "\n")
    if slice.utf8.count <= maxBytes { return slice }
    let truncated = String(decoding: slice.utf8.prefix(maxBytes), as: UTF8.self)
    return truncated
}