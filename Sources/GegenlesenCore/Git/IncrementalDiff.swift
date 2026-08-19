import Foundation

public enum IncrementalDiff: Sendable {
    public static func compute(
        identified: ChangeSet,
        workspace: URL,
        blobs: BlobStore,
        jobID: JobID,
        parentHeadSHA: String,
        parentFiles: [JobFile],
        parentWorkspace: URL?,
        timeout: Duration
    ) throws -> ChangeSet {
        let deadline = Date().addingTimeInterval(timeout.timeInterval)
        let newHead = identified.headSHA
        if let gitSet = try gitInterdiff(
            workspace: workspace,
            blobs: blobs,
            jobID: jobID,
            parentHeadSHA: parentHeadSHA,
            newHead: newHead,
            source: identified.source,
            deadline: deadline
        ) {
            return gitSet
        }
        return try hashInterdiff(
            identified: identified,
            workspace: workspace,
            blobs: blobs,
            jobID: jobID,
            parentHeadSHA: parentHeadSHA,
            parentFiles: parentFiles,
            parentWorkspace: parentWorkspace
        )
    }

    private static func gitInterdiff(
        workspace: URL,
        blobs: BlobStore,
        jobID: JobID,
        parentHeadSHA: String,
        newHead: String,
        source: ChangeSet.Source,
        deadline: Date
    ) throws -> ChangeSet? {
        do {
            try fetchBundleIfPresent(workspace: workspace, deadline: deadline)
        } catch let error as IdentifyError where error == .timeout {
            throw error
        } catch {
            // Bundle optional; a packed workspace may already have .git.
        }
        guard hasGitDirectory(workspace) else { return nil }
        let git = GitRunner(workspace: workspace, deadline: deadline)
        guard objectExists(parentHeadSHA, git: git) else { return nil }
        let head = resolveGitHead(newHead, git: git)
        guard let head, objectExists(head, git: git) else { return nil }
        do {
            let patch = try git.run([
                "diff", "--no-ext-diff", "--no-color", "--find-renames", parentHeadSHA, head,
            ])
            try writePatch(Data(patch.utf8), blobs: blobs, jobID: jobID, workspace: workspace)
            let nameStatus = try git.run([
                "diff", "--no-ext-diff", "--name-status", "--find-renames", parentHeadSHA, head,
            ])
            var files = NameStatus.parse(nameStatus, jobID: jobID)
            try enrich(files: &files, workspace: workspace)
            let fromBundle = FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent(".gegenlesen/history.bundle").path
            )
            return ChangeSet(
                baseSHA: parentHeadSHA,
                headSHA: head,
                patchRelativePath: "blobs/patches/\(jobID.rawValue).patch",
                files: files,
                source: fromBundle || source == .bundle ? .bundle : .git
            )
        } catch let error as IdentifyError where error == .timeout {
            throw error
        } catch {
            return nil
        }
    }

    private static func resolveGitHead(_ newHead: String, git: GitRunner) -> String? {
        let trimmed = newHead.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != "noparent" {
            if let resolved = try? git.run(["rev-parse", trimmed]) {
                let sha = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sha.isEmpty { return sha }
            }
            if objectExists(trimmed, git: git) { return trimmed }
        }
        if let resolved = try? git.run(["rev-parse", "HEAD"]) {
            let sha = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }
        return nil
    }

    private static func fetchBundleIfPresent(workspace: URL, deadline: Date) throws {
        let bundle = workspace.appendingPathComponent(".gegenlesen/history.bundle")
        guard FileManager.default.fileExists(atPath: bundle.path) else { return }
        let git = GitRunner(workspace: workspace, deadline: deadline)
        if !hasGitDirectory(workspace) {
            let gitURL = workspace.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: gitURL.path, isDirectory: &isDir), !isDir.boolValue {
                try FileManager.default.removeItem(at: gitURL)
            }
            try git.run(["init"])
        }
        do {
            _ = try git.run(["fetch", ".gegenlesen/history.bundle", "+refs/*:refs/bundle/*"])
        } catch {
            _ = try git.run(["fetch", ".gegenlesen/history.bundle", "HEAD:refs/heads/bundle-head"])
        }
    }

    private static func hashInterdiff(
        identified: ChangeSet,
        workspace: URL,
        blobs: BlobStore,
        jobID: JobID,
        parentHeadSHA: String,
        parentFiles: [JobFile],
        parentWorkspace: URL?
    ) throws -> ChangeSet {
        let ws = Workspace(root: workspace)
        let parentByPath = Dictionary(uniqueKeysWithValues: parentFiles.map { ($0.path, $0) })
        var paths = Set(parentFiles.map(\.path))
        for file in identified.files {
            paths.insert(file.path)
            if let old = file.oldPath { paths.insert(old) }
        }
        for file in parentFiles {
            if let old = file.oldPath { paths.insert(old) }
        }

        struct Snap {
            var path: String
            var sha: String?
            var exists: Bool
            var identified: JobFile?
        }

        var snaps: [String: Snap] = [:]
        for path in paths {
            let url = ws.resolveForRead(path)
            let exists = url != nil
            let sha = url.flatMap { try? ContentHash.sha256(fileAt: $0) }
            snaps[path] = Snap(
                path: path,
                sha: sha,
                exists: exists,
                identified: identified.files.first { $0.path == path }
            )
        }

        var parentOnly: [JobFile] = []
        var childOnly: [Snap] = []
        var files: [JobFile] = []

        for path in paths.sorted() {
            let snap = snaps[path]!
            let parent = parentByPath[path]
            if let parent, snap.exists, snap.sha != nil, snap.sha == parent.sha256 {
                continue
            }
            if let parent, !snap.exists {
                parentOnly.append(parent)
                continue
            }
            if parent == nil, snap.exists {
                childOnly.append(snap)
                continue
            }
            if let parent, snap.exists, snap.sha != parent.sha256 {
                files.append(
                    JobFile(
                        jobID: jobID,
                        path: path,
                        sha256: snap.sha,
                        status: .modified,
                        oldPath: snap.identified?.oldPath ?? parent.oldPath,
                        language: LanguageMap.language(forPath: path),
                        bytes: byteCount(ws.resolveForRead(path))
                    )
                )
            }
        }

        var claimedParents = Set<String>()
        for snap in childOnly {
            let bySHA = parentOnly.first { file in
                !claimedParents.contains(file.path) && file.sha256 != nil && file.sha256 == snap.sha
            }
            let byParentOldPath = parentFiles.first { file in
                !claimedParents.contains(file.path) && file.oldPath == snap.path
            }
            let byIdentifiedOld = parentOnly.first { file in
                !claimedParents.contains(file.path) && snap.identified?.oldPath == file.path
            }
            let byIdentifiedOldOnParent = parentFiles.first { file in
                !claimedParents.contains(file.path) && snap.identified?.oldPath == file.path
            }
            if let old = bySHA ?? byParentOldPath ?? byIdentifiedOld ?? byIdentifiedOldOnParent {
                claimedParents.insert(old.path)
                files.append(
                    JobFile(
                        jobID: jobID,
                        path: snap.path,
                        sha256: snap.sha,
                        status: .renamed,
                        oldPath: old.path,
                        language: LanguageMap.language(forPath: snap.path),
                        bytes: byteCount(ws.resolveForRead(snap.path))
                    )
                )
            } else if snap.identified?.status == .renamed, let oldPath = snap.identified?.oldPath {
                claimedParents.insert(oldPath)
                files.append(
                    JobFile(
                        jobID: jobID,
                        path: snap.path,
                        sha256: snap.sha,
                        status: .renamed,
                        oldPath: oldPath,
                        language: LanguageMap.language(forPath: snap.path),
                        bytes: byteCount(ws.resolveForRead(snap.path))
                    )
                )
            } else {
                files.append(
                    JobFile(
                        jobID: jobID,
                        path: snap.path,
                        sha256: snap.sha,
                        status: .added,
                        oldPath: snap.identified?.oldPath,
                        language: LanguageMap.language(forPath: snap.path),
                        bytes: byteCount(ws.resolveForRead(snap.path))
                    )
                )
            }
        }

        for parent in parentOnly where !claimedParents.contains(parent.path) {
            files.append(
                JobFile(
                    jobID: jobID,
                    path: parent.path,
                    sha256: parent.sha256,
                    status: .deleted,
                    oldPath: parent.oldPath,
                    language: parent.language ?? LanguageMap.language(forPath: parent.path),
                    bytes: parent.bytes
                )
            )
        }

        let patch = buildPatch(
            files: files,
            child: workspace,
            parent: parentWorkspace
        )
        try writePatch(Data(patch.utf8), blobs: blobs, jobID: jobID, workspace: workspace)
        return ChangeSet(
            baseSHA: parentHeadSHA,
            headSHA: identified.headSHA,
            patchRelativePath: "blobs/patches/\(jobID.rawValue).patch",
            files: files,
            source: .hashInterdiff
        )
    }

    private static func buildPatch(files: [JobFile], child: URL, parent: URL?) -> String {
        var parts: [String] = []
        let childWS = Workspace(root: child)
        let parentWS = parent.map { Workspace(root: $0) }
        let parentAlive = parent.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        for file in files.sorted(by: { $0.path < $1.path }) {
            let newURL = childWS.resolveForRead(file.path)
            let oldPath = file.oldPath ?? file.path
            let oldURL = parentAlive ? parentWS?.resolveForRead(oldPath) : nil
            switch file.status {
            case .deleted:
                parts.append(unixDiff(old: oldURL, new: nil, path: file.path, oldPath: oldPath))
            case .added:
                parts.append(unixDiff(old: nil, new: newURL, path: file.path, oldPath: file.path))
            case .modified, .renamed:
                if parentAlive, oldURL != nil {
                    parts.append(unixDiff(old: oldURL, new: newURL, path: file.path, oldPath: oldPath))
                } else {
                    parts.append(unixDiff(old: nil, new: newURL, path: file.path, oldPath: file.path))
                }
            }
        }
        return parts.filter { !$0.isEmpty }.joined()
    }

    private static func unixDiff(old: URL?, new: URL?, path: String, oldPath: String) -> String {
        let oldArg = old?.path ?? "/dev/null"
        let newArg = new?.path ?? "/dev/null"
        let oldLabel = old == nil ? "/dev/null" : "a/\(oldPath)"
        let newLabel = new == nil ? "/dev/null" : "b/\(path)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        process.arguments = ["-u", "--label", oldLabel, "--label", newLabel, oldArg, newArg]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return fallbackDiff(old: old, new: new, path: path)
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func fallbackDiff(old: URL?, new: URL?, path: String) -> String {
        let newText = new.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        if old == nil {
            let lines = newText.split(separator: "\n", omittingEmptySubsequences: false)
            var body = "--- /dev/null\n+++ b/\(path)\n@@ -0,0 +\(lines.count == 0 ? 0 : 1),\(max(lines.count, 1)) @@\n"
            for line in newText.split(separator: "\n", omittingEmptySubsequences: false) {
                body += "+\(line)\n"
            }
            return body
        }
        return ""
    }

    private static func objectExists(_ sha: String, git: GitRunner) -> Bool {
        if (try? git.run(["cat-file", "-e", "\(sha)^{commit}"])) != nil {
            return true
        }
        return (try? git.run(["cat-file", "-e", sha])) != nil
    }

    private static func hasGitDirectory(_ workspace: URL) -> Bool {
        var isDir: ObjCBool = false
        let git = workspace.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func writePatch(_ data: Data, blobs: BlobStore, jobID: JobID, workspace: URL) throws {
        try FileManager.default.createDirectory(at: blobs.patches, withIntermediateDirectories: true)
        try data.write(to: blobs.patchURL(jobID: jobID.rawValue), options: .atomic)
        let dest = workspace.appendingPathComponent(".gegenlesen/diff.patch")
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: dest, options: .atomic)
    }

    private static func enrich(files: inout [JobFile], workspace: URL) throws {
        let ws = Workspace(root: workspace)
        let fm = FileManager.default
        for index in files.indices {
            files[index].language = LanguageMap.language(forPath: files[index].path)
            if files[index].status == .deleted { continue }
            guard let url = ws.resolveForRead(files[index].path) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            files[index].sha256 = try ContentHash.sha256(fileAt: url)
            files[index].bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }
    }

    private static func byteCount(_ url: URL?) -> Int? {
        guard let url else { return nil }
        return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }
}
