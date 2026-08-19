import Foundation

public enum Evidence: Sendable {
    public static func actualSlice(
        filePath: String,
        startLine: Int,
        endLine: Int,
        workspace: Workspace
    ) -> String {
        guard let url = workspace.resolveForRead(filePath),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return ""
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard startLine >= 1, startLine <= lines.count else { return "" }
        let start = startLine - 1
        let end = min(endLine, lines.count)
        guard end > start else { return "" }
        return lines[start..<end].joined(separator: "\n")
    }

    public static func snippetPresent(snippet: String, in slice: String) -> Bool {
        Fingerprint.normalizeWhitespace(slice)
            .contains(Fingerprint.normalizeWhitespace(snippet))
    }

    public static func evidenceOK(
        filePath: String,
        startLine: Int,
        endLine: Int,
        snippet: String,
        workspace: Workspace
    ) -> Bool {
        let slice = actualSlice(
            filePath: filePath,
            startLine: startLine,
            endLine: endLine,
            workspace: workspace
        )
        guard !slice.isEmpty else { return false }
        return snippetPresent(snippet: snippet, in: slice)
    }
}
