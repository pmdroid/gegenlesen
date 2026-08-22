import Foundation

public struct FindingMatcher: Sendable {
    public var jobID: JobID

    public init(jobID: JobID) {
        self.jobID = jobID
    }

    public func carryForward(
        parent: [Finding],
        parentFiles: [JobFile],
        child: ChangeSet,
        workspace: Workspace
    ) -> [Finding] {
        let now = Date()
        return parent.compactMap { finding in
            carryOne(
                parent: finding,
                parentFiles: parentFiles,
                child: child,
                workspace: workspace,
                now: now
            )
        }
    }

    public func collapse(child: Finding, parents: [Finding], childFiles: [JobFile]) -> Finding? {
        collapse(child: child, parents: parents, childFiles: childFiles, parentFiles: [])
    }

    public func collapse(
        child: Finding,
        parents: [Finding],
        childFiles: [JobFile],
        parentFiles: [JobFile]
    ) -> Finding? {
        for parent in parents {
            guard parent.ruleID == child.ruleID else { continue }
            let childText = Normalize.whitespace(child.title + "\n" + child.message)
            let parentText = Normalize.whitespace(parent.title + "\n" + parent.message)
            guard childText == parentText else { continue }
            let paths = Self.paths(parent: parent, child: child, childFiles: childFiles, parentFiles: parentFiles)
            guard pathRelated(child: child, parent: parent, paths: paths) else { continue }
            guard fingerprintMatches(child: child, parent: parent, paths: paths) else { continue }
            var collapsed = child
            collapsed.lifecycle = .stillOpen
            collapsed.parentFindingID = parent.id
            if collapsed.fingerprint == nil {
                collapsed.fingerprint = Fingerprint.sha256(
                    ruleID: collapsed.ruleID,
                    path: collapsed.filePath ?? "",
                    snippet: collapsed.snippet ?? ""
                )
            }
            return collapsed
        }
        return nil
    }

    private func carryOne(
        parent: Finding,
        parentFiles: [JobFile],
        child: ChangeSet,
        workspace: Workspace,
        now: Date
    ) -> Finding? {
        guard let original = parent.filePath, !original.isEmpty else {
            return copy(parent, lifecycle: .stillOpen, path: parent.filePath, start: parent.startLine, end: parent.endLine, now: now)
        }

        let path = Self.currentPath(original: original, childFiles: child.files, parentFiles: parentFiles)
        let childFile = child.files.first { $0.path == path || $0.oldPath == original }
        if childFile?.status == .deleted {
            return copy(parent, lifecycle: .resolved, path: path, start: parent.startLine, end: parent.endLine, now: now)
        }

        let childSHA = Self.sha256(path: path, files: child.files, workspace: workspace)
        let parentSHA = parentFiles.first { $0.path == original || $0.oldPath == original }?.sha256
            ?? parentFiles.first { $0.path == path }?.sha256
        let text = Self.fileText(path: path, workspace: workspace)
        if text == nil, childSHA == nil {
            return copy(parent, lifecycle: .resolved, path: path, start: parent.startLine, end: parent.endLine, now: now)
        }

        let sameSHA = childSHA != nil && childSHA == parentSHA
        if sameSHA {
            return copy(parent, lifecycle: .stillOpen, path: path, start: parent.startLine, end: parent.endLine, now: now)
        }

        let hits = Self.snippetHits(in: text ?? "", snippet: parent.snippet ?? "")
        if hits.isEmpty {
            return copy(parent, lifecycle: .resolved, path: path, start: parent.startLine, end: parent.endLine, now: now)
        }
        if hits.count >= 2 {
            return nil
        }
        let hit = hits[0]
        if hit.start == parent.startLine, hit.end == parent.endLine {
            return copy(parent, lifecycle: .stillOpen, path: path, start: hit.start, end: hit.end, now: now)
        }
        return copy(parent, lifecycle: .relocated, path: path, start: hit.start, end: hit.end, now: now)
    }

    private func copy(
        _ parent: Finding,
        lifecycle: FindingLifecycle,
        path: String?,
        start: Int?,
        end: Int?,
        now: Date
    ) -> Finding {
        Finding(
            id: FindingID.generate(at: now),
            jobID: jobID,
            ruleID: parent.ruleID,
            phase: parent.phase,
            reviewerSlot: parent.reviewerSlot,
            severity: parent.severity,
            title: parent.title,
            message: parent.message,
            filePath: path,
            startLine: start,
            endLine: end,
            snippet: parent.snippet,
            agentRationale: parent.agentRationale,
            judgeVerdict: parent.judgeVerdict,
            judgeSeverity: parent.judgeSeverity,
            judgeRationale: parent.judgeRationale,
            confidence: parent.confidence,
            lifecycle: lifecycle,
            parentFindingID: parent.id,
            suggestedPatch: parent.suggestedPatch,
            fingerprint: Fingerprint.sha256(ruleID: parent.ruleID, path: path ?? "", snippet: parent.snippet ?? ""),
            evidenceOK: parent.evidenceOK,
            createdAt: now
        )
    }

    private func pathRelated(child: Finding, parent: Finding, paths: Set<String>) -> Bool {
        if let childPath = child.filePath, paths.contains(childPath) {
            return true
        }
        if let parentPath = parent.filePath, paths.contains(parentPath) {
            return child.filePath == nil || paths.contains(child.filePath ?? "")
        }
        return child.filePath == nil && parent.filePath == nil
    }

    private func fingerprintMatches(child: Finding, parent: Finding, paths: Set<String>) -> Bool {
        let childSnippet = child.snippet ?? ""
        let parentSnippet = parent.snippet ?? ""
        let candidates = paths.isEmpty ? [""] : Array(paths)
        for path in candidates {
            let childFP = Fingerprint.sha256(ruleID: child.ruleID, path: path, snippet: childSnippet)
            let parentFP = Fingerprint.sha256(ruleID: parent.ruleID, path: path, snippet: parentSnippet)
            if childFP == parentFP {
                return true
            }
        }
        return false
    }

    static func paths(
        parent: Finding,
        child: Finding,
        childFiles: [JobFile],
        parentFiles: [JobFile]
    ) -> Set<String> {
        var result = Set<String>()
        if let path = parent.filePath, !path.isEmpty {
            result.insert(path)
        }
        if let old = parentFiles.first(where: { $0.path == parent.filePath })?.oldPath {
            result.insert(old)
        }
        if let childPath = child.filePath, let old = childFiles.first(where: { $0.path == childPath })?.oldPath {
            result.insert(old)
            result.insert(childPath)
        }
        if let parentPath = parent.filePath, let renamed = childFiles.first(where: { $0.oldPath == parentPath }) {
            result.insert(renamed.path)
        }
        return result
    }

    static func currentPath(original: String, childFiles: [JobFile], parentFiles: [JobFile]) -> String {
        if let renamed = childFiles.first(where: { $0.oldPath == original }) {
            return renamed.path
        }
        if childFiles.contains(where: { $0.path == original }) {
            return original
        }
        if let parentRename = parentFiles.first(where: { $0.oldPath == original }) {
            if let next = childFiles.first(where: { $0.oldPath == parentRename.path || $0.path == parentRename.path }) {
                return next.path
            }
            return parentRename.path
        }
        return original
    }

    static func sha256(path: String, files: [JobFile], workspace: Workspace) -> String? {
        if let sha = files.first(where: { $0.path == path })?.sha256 {
            return sha
        }
        guard let url = workspace.resolveForRead(path) else { return nil }
        return try? ContentHash.sha256(fileAt: url)
    }

    static func fileText(path: String, workspace: Workspace) -> String? {
        guard let url = workspace.resolveForRead(path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    struct LineRange: Equatable {
        var start: Int
        var end: Int
    }

    static func snippetHits(in text: String, snippet: String) -> [LineRange] {
        let needle = Normalize.whitespace(snippet)
        guard !needle.isEmpty else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var hits: [LineRange] = []
        for start in lines.indices {
            var chunk = ""
            chunk.reserveCapacity(min(snippet.count, 4096))
            for end in start..<lines.count {
                if !chunk.isEmpty { chunk.append("\n") }
                chunk.append(contentsOf: lines[end])
                let hay = Normalize.whitespace(chunk)
                if hay == needle {
                    hits.append(LineRange(start: start + 1, end: end + 1))
                    break
                }
                if hay.count > needle.count {
                    break
                }
            }
        }
        return hits
    }
}
