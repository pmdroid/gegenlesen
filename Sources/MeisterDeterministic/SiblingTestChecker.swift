import Foundation
import MeisterCore

public struct SiblingTestChecker: DeterministicChecker {
    public init() {}

    public func check(file: JobFile, bytes: Data, workspace: Workspace, rule: Rule) throws -> [FindingDraft] {
        guard case .siblingTest(let sourceGlob, let testTemplate) = rule.payload else { return [] }
        guard PathGlob([sourceGlob]).matches(file.path) else { return [] }
        let expected = Self.expectedTestPath(source: file.path, template: testTemplate)
        if let url = workspace.resolveForRead(expected),
           FileManager.default.fileExists(atPath: url.path) {
            return []
        }
        return [
            FindingDraft(
                ruleID: rule.id,
                phase: .deterministic,
                severity: rule.severity,
                title: rule.title,
                message: "Missing sibling test \(expected)",
                filePath: file.path,
                startLine: 1,
                endLine: 1,
                snippet: expected
            ),
        ]
    }

    public static func expectedTestPath(source: String, template: String) -> String {
        let normalized = PathGlob.normalize(source)
        let name = (normalized as NSString).lastPathComponent
        let dir = (normalized as NSString).deletingLastPathComponent
        let stem: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            stem = String(name[..<dot])
        } else {
            stem = name
        }
        var rendered = template
            .replacingOccurrences(of: "{stem}", with: stem)
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{dir}", with: dir)
        if !rendered.contains("/") {
            rendered = dir.isEmpty ? rendered : dir + "/" + rendered
        }
        return PathGlob.normalize(rendered)
    }
}