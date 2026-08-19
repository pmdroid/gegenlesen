import Foundation
import GegenlesenCore

public struct DenyListChecker: DeterministicChecker {
    public init() {}

    public func check(file: JobFile, bytes: Data, workspace: Workspace, rule: Rule) throws -> [FindingDraft] {
        guard case .denyAPI(let symbols, let message) = rule.payload else { return [] }
        let text = String(decoding: bytes, as: UTF8.self)
        var drafts: [FindingDraft] = []
        for symbol in symbols where !symbol.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: symbol)
            let regex = try Regex("\\b\(escaped)\\b")
            for match in text.matches(of: regex) {
                let start = lineNumber(of: match.range.lowerBound, in: text)
                let end = lineNumber(of: match.range.upperBound, in: text)
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
                        snippet: lineSlice(in: text, start: start, end: end)
                    )
                )
            }
        }
        return drafts
    }
}