import Foundation

public struct ChangeSet: Sendable, Equatable {
    public var baseSHA: String
    public var headSHA: String
    public var patchRelativePath: String
    public var files: [JobFile]
    public var source: Source
    /// How baseSHA was chosen, e.g. "base_ref:main", "merge_base:origin/main",
    /// "parent_of_head", "empty_tree". Nil when the path did not resolve a base.
    public var baseSource: String?

    public enum Source: String, Sendable, Equatable {
        case embeddedDiff
        case git
        case bundle
        case multipartPatch
        case hashInterdiff
    }

    public init(
        baseSHA: String,
        headSHA: String,
        patchRelativePath: String,
        files: [JobFile],
        source: Source,
        baseSource: String? = nil
    ) {
        self.baseSHA = baseSHA
        self.headSHA = headSHA
        self.patchRelativePath = patchRelativePath
        self.files = files
        self.source = source
        self.baseSource = baseSource
    }
}

public struct IdentifyMeta: Sendable, Equatable {
    public var baseSHA: String?
    public var headSHA: String?
    public var baseRef: String?
    public var headRef: String?
    public var parentHeadSHA: String?

    public init(
        baseSHA: String? = nil,
        headSHA: String? = nil,
        baseRef: String? = nil,
        headRef: String? = nil,
        parentHeadSHA: String? = nil
    ) {
        self.baseSHA = baseSHA
        self.headSHA = headSHA
        self.baseRef = baseRef
        self.headRef = headRef
        self.parentHeadSHA = parentHeadSHA
    }
}

public struct IdentifyError: Error, Equatable, Sendable {
    public var errorMessage: String

    public init(errorMessage: String) {
        self.errorMessage = errorMessage
    }

    public static let noChangeSet = IdentifyError(errorMessage: "no_change_set")
    public static let timeout = IdentifyError(errorMessage: "identify_timeout")
}

public struct WidePackSignal: Sendable, Equatable {
    public var base: String
    public var baseSource: String?
    public var packFiles: Int
    public var headOwnFiles: Int
}

/// Flags an identified pack that is wildly larger than the head commit's own
/// diff — the signature of a guessed base resolving to an ancient commit.
public enum PackSignals: Sendable {
    /// A 292-file pack for a 2-file commit should be visible in the job, not
    /// something an operator reconstructs afterwards.
    public static func isWide(packFiles: Int, headOwnFiles: Int?) -> Bool {
        guard let headOwnFiles else { return false }
        return packFiles > 20 && packFiles >= headOwnFiles * 10
    }

    public static func headOwnFileCount(workspace: URL, head: String, timeout: Duration) -> Int? {
        diffFileCount(workspace: workspace, from: "\(head)^", to: head, timeout: timeout)
    }

    public static func diffFileCount(workspace: URL, from: String, to: String, timeout: Duration) -> Int? {
        let git = GitRunner(workspace: workspace, deadline: Date().addingTimeInterval(timeout.timeInterval))
        guard let output = try? git.run(["diff", "--name-only", from, to]) else {
            return nil
        }
        return output.split(whereSeparator: \.isNewline).count
    }

    public static func evaluate(
        changeSet: ChangeSet,
        workspace: URL,
        timeout: Duration = .seconds(30)
    ) -> WidePackSignal? {
        let headOwn = headOwnFileCount(workspace: workspace, head: changeSet.headSHA, timeout: timeout)
        guard isWide(packFiles: changeSet.files.count, headOwnFiles: headOwn) else {
            return nil
        }
        return WidePackSignal(
            base: changeSet.baseSHA,
            baseSource: changeSet.baseSource,
            packFiles: changeSet.files.count,
            headOwnFiles: headOwn ?? 0
        )
    }
}

public struct ChangeSetIdentifier: Sendable {
    public static let emptyTreeSHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    public var workspace: URL
    public var blobs: BlobStore
    public var jobID: JobID
    public var meta: IdentifyMeta
    public var multipartPatch: Data?
    public var timeout: Duration

    public init(
        workspace: URL,
        blobs: BlobStore,
        jobID: JobID,
        meta: IdentifyMeta = IdentifyMeta(),
        multipartPatch: Data? = nil,
        timeout: Duration = .seconds(60)
    ) {
        self.workspace = workspace
        self.blobs = blobs
        self.jobID = jobID
        self.meta = meta
        self.multipartPatch = multipartPatch
        self.timeout = timeout
    }

    public func identify() throws -> ChangeSet {
        let deadline = Date().addingTimeInterval(timeout.timeInterval)
        try blobs.ensureLayout()

        if let changeSet = try identifyEmbedded() {
            return changeSet
        }
        if let changeSet = try identifyFromHistory(deadline: deadline) {
            return changeSet
        }
        if let changeSet = try identifyMultipart(deadline: deadline) {
            return changeSet
        }
        throw IdentifyError.noChangeSet
    }

    private func identifyEmbedded() throws -> ChangeSet? {
        let embedded = workspace.appendingPathComponent(".gegenlesen/diff.patch")
        guard FileManager.default.fileExists(atPath: embedded.path) else {
            return nil
        }
        let data = try Data(contentsOf: embedded)
        try writePatch(data)
        var files = UnifiedDiff.parse(data, jobID: jobID)
        try enrich(files: &files)

        let base = firstNonEmpty([
            meta.baseSHA,
            readGegenlesenFile("base_sha"),
            ContentHash.sha256(data),
        ]) ?? ContentHash.sha256(data)
        let head = firstNonEmpty([
            meta.headSHA,
            readGegenlesenFile("head_sha"),
            "noparent",
        ]) ?? "noparent"
        return ChangeSet(
            baseSHA: base,
            headSHA: head,
            patchRelativePath: patchRelativePath,
            files: files,
            source: .embeddedDiff
        )
    }

    private func identifyFromHistory(deadline: Date) throws -> ChangeSet? {
        var source: ChangeSet.Source?
        if hasGitDirectory {
            source = .git
        } else if FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(".gegenlesen/history.bundle").path
        ) {
            do {
                try fetchBundle(deadline: deadline)
            } catch let error as IdentifyError where error == .timeout {
                throw error
            } catch {
                return nil
            }
            source = .bundle
            try checkoutHead(deadline: deadline)
        }
        guard let source else {
            return nil
        }

        let git = GitRunner(workspace: workspace, deadline: deadline)
        do {
            let head = try resolveHead(git: git)
            let base = try resolveBase(git: git, head: head)
            let patch = try git.run([
                "diff", "--no-ext-diff", "--no-color", "--find-renames", base.sha, head,
            ])
            try writePatch(Data(patch.utf8))
            let nameStatus = try git.run([
                "diff", "--no-ext-diff", "--name-status", "--find-renames", base.sha, head,
            ])
            var files = NameStatus.parse(nameStatus, jobID: jobID)
            try enrich(files: &files)
            return ChangeSet(
                baseSHA: base.sha,
                headSHA: head,
                patchRelativePath: patchRelativePath,
                files: files,
                source: source,
                baseSource: base.source
            )
        } catch let error as IdentifyError where error == .timeout {
            throw error
        } catch {
            return nil
        }
    }

    private func identifyMultipart(deadline: Date) throws -> ChangeSet? {
        guard let patch = multipartPatch, !patch.isEmpty else {
            return nil
        }
        let git = GitRunner(workspace: workspace, deadline: deadline)
        if !hasGitDirectory {
            try removeNonDirectoryGit()
            try git.run(["init"])
        }
        let startsWithFrom = patch.starts(with: Data("From ".utf8))
        let patchFile = workspace.appendingPathComponent(".gegenlesen/multipart.patch")
        try FileManager.default.createDirectory(
            at: patchFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try patch.write(to: patchFile)
        if startsWithFrom {
            try git.run(["am", "--3way", patchFile.path])
        } else {
            try git.run(["apply", "--reject", "--whitespace=nowarn", patchFile.path])
        }
        try writePatch(patch)
        var files = UnifiedDiff.parse(patch, jobID: jobID)
        try enrich(files: &files)
        return ChangeSet(
            baseSHA: firstNonEmpty([meta.parentHeadSHA, "noparent"]) ?? "noparent",
            headSHA: ContentHash.sha256(patch),
            patchRelativePath: patchRelativePath,
            files: files,
            source: .multipartPatch
        )
    }

    private var hasGitDirectory: Bool {
        var isDir: ObjCBool = false
        let git = workspace.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    private func removeNonDirectoryGit() throws {
        let git = workspace.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) else {
            return
        }
        if !isDir.boolValue {
            try FileManager.default.removeItem(at: git)
        }
    }

    private func fetchBundle(deadline: Date) throws {
        let git = GitRunner(workspace: workspace, deadline: deadline)
        if !hasGitDirectory {
            try removeNonDirectoryGit()
            try git.run(["init"])
        }
        let bundle = ".gegenlesen/history.bundle"
        do {
            _ = try git.run(["fetch", bundle, "+refs/*:refs/bundle/*"])
        } catch {
            _ = try git.run(["fetch", bundle, "HEAD:refs/heads/bundle-head"])
        }
    }

    private func checkoutHead(deadline: Date) throws {
        let git = GitRunner(workspace: workspace, deadline: deadline)
        var candidates: [String] = []
        if let sha = firstNonEmpty([meta.headSHA, readGegenlesenFile("head_sha")]) {
            candidates.append(sha)
        }
        if let refs = try? git.run([
            "for-each-ref", "--format=%(refname)", "refs/bundle/heads",
        ]) {
            for line in refs.split(whereSeparator: \.isNewline) where !line.isEmpty {
                candidates.append(String(line))
            }
        }
        candidates.append("refs/heads/bundle-head")

        var lastError: Error?
        var seen = Set<String>()
        for ref in candidates where seen.insert(ref).inserted {
            do {
                _ = try git.run(["checkout", "--force", ref])
                return
            } catch let error as IdentifyError where error == .timeout {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError ?? IdentifyError(errorMessage: "checkout failed")
    }

    private func resolveHead(git: GitRunner) throws -> String {
        if let sha = firstNonEmpty([meta.headSHA, readGegenlesenFile("head_sha")]) {
            return sha
        }
        let ref = meta.headRef ?? "HEAD"
        return try git.run(["rev-parse", ref]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveBase(git: GitRunner, head: String) throws -> (sha: String, source: String) {
        if let sha = firstNonEmpty([meta.baseSHA, readGegenlesenFile("base_sha")]) {
            return (sha, "explicit_sha")
        }
        if let ref = meta.baseRef, !ref.isEmpty {
            Self.fetchRef(git, ref)
            if let sha = Self.resolveFetched(git, ref) {
                return (sha, "base_ref:\(ref)")
            }
        }
        for name in ["main", "master", "trunk"] {
            // A throwaway worktree's refs can be arbitrarily stale; fetch the
            // upstream copy first so the pack cannot silently widen to an
            // ancient merge-base.
            Self.fetchRef(git, name)
            if let sha = Self.mergeBase(git, "origin/\(name)", head) {
                return (sha, "merge_base:origin/\(name)")
            }
            if let sha = Self.mergeBase(git, name, head) {
                return (sha, "merge_base:\(name)")
            }
        }
        Self.fetchRef(git, "HEAD")
        if let sha = Self.mergeBase(git, "origin/HEAD", head) {
            return (sha, "merge_base:origin/HEAD")
        }
        if let parent = try? git.run(["rev-parse", "\(head)^"]) {
            let trimmed = parent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return (trimmed, "parent_of_head") }
        }
        return (Self.emptyTreeSHA, "empty_tree")
    }

    /// Best-effort `git fetch origin <ref>`; a failed or missing remote is
    /// not an error — resolution falls back to whatever refs exist locally.
    private static func fetchRef(_ git: GitRunner, _ ref: String) {
        let name = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !name.hasPrefix("refs/"),
              name.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) == nil
        else {
            return
        }
        _ = try? git.run(["fetch", "--quiet", "--no-tags", "origin", name])
    }

    /// Resolve an explicit base ref against its freshly fetched remote copy
    /// first (origin/<ref>), falling back to the ref as given.
    private static func resolveFetched(_ git: GitRunner, _ ref: String) -> String? {
        let candidates: [String]
        if ref.hasPrefix("origin/") {
            let local = String(ref.dropFirst("origin/".count))
            candidates = [ref, local]
        } else {
            candidates = ["origin/\(ref)", ref]
        }
        for candidate in candidates {
            if let resolved = try? git.run(["rev-parse", candidate]) {
                let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func mergeBase(_ git: GitRunner, _ ref: String, _ head: String) -> String? {
        guard let merge = try? git.run(["merge-base", ref, head]) else {
            return nil
        }
        let trimmed = merge.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func writePatch(_ data: Data) throws {
        try FileManager.default.createDirectory(at: blobs.patches, withIntermediateDirectories: true)
        try data.write(to: blobs.patchURL(jobID: jobID.rawValue), options: .atomic)
    }

    private var patchRelativePath: String {
        "blobs/patches/\(jobID.rawValue).patch"
    }

    private func readGegenlesenFile(_ name: String) -> String? {
        let url = workspace.appendingPathComponent(".gegenlesen/\(name)")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func enrich(files: inout [JobFile]) throws {
        let ws = Workspace(root: workspace)
        let fm = FileManager.default
        for index in files.indices {
            files[index].language = LanguageMap.language(forPath: files[index].path)
            if files[index].status == .deleted {
                continue
            }
            guard let url = ws.resolveForRead(files[index].path) else {
                continue
            }
            let resolved = url.resolvingSymlinksInPath()
            guard Self.isContained(resolved, root: workspace) else {
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            files[index].sha256 = try ContentHash.sha256(fileAt: resolved)
            files[index].bytes = try resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }
    }

    private static func isContained(_ url: URL, root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath {
            return true
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix)
    }
}

extension Duration {
    public var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

enum UnifiedDiff {
    static func parse(_ data: Data, jobID: JobID) -> [JobFile] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var files: [JobFile] = []
        var path: String?
        var oldPath: String?
        var status: FileChangeStatus = .modified

        func flush() {
            guard let path, !path.isEmpty, path != "/dev/null" else { return }
            files.append(
                JobFile(
                    jobID: jobID,
                    path: path,
                    status: status,
                    oldPath: status == .renamed ? oldPath : nil
                )
            )
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if line.hasPrefix("diff --git ") {
                flush()
                let parsed = parseGitLine(line)
                oldPath = parsed.old
                path = parsed.new
                status = .modified
            } else if line.hasPrefix("new file mode") {
                status = .added
            } else if line.hasPrefix("deleted file mode") {
                status = .deleted
            } else if line.hasPrefix("rename from ") {
                status = .renamed
                oldPath = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                status = .renamed
                path = String(line.dropFirst("rename to ".count))
            }
        }
        flush()
        return files
    }

    private static func parseGitLine(_ line: String) -> (old: String?, new: String?) {
        let rest = line.dropFirst("diff --git ".count)
        guard let split = splitAB(String(rest)) else {
            return (nil, nil)
        }
        return (stripPrefix(split.0), stripPrefix(split.1))
    }

    private static func splitAB(_ rest: String) -> (String, String)? {
        guard rest.hasPrefix("a/") else { return nil }
        guard let bRange = rest.range(of: " b/") else { return nil }
        let old = String(rest[rest.startIndex..<bRange.lowerBound])
        let new = String(rest[bRange.upperBound...])
        return (old, "b/" + new)
    }

    private static func stripPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }
}

enum NameStatus {
    static func parse(_ text: String, jobID: JobID) -> [JobFile] {
        var files: [JobFile] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let code = parts.first, let flag = code.first else { continue }
            switch flag {
            case "A":
                guard parts.count >= 2 else { continue }
                files.append(JobFile(jobID: jobID, path: parts[1], status: .added))
            case "M", "T":
                guard parts.count >= 2 else { continue }
                files.append(JobFile(jobID: jobID, path: parts[1], status: .modified))
            case "D":
                guard parts.count >= 2 else { continue }
                files.append(JobFile(jobID: jobID, path: parts[1], status: .deleted))
            case "R":
                guard parts.count >= 3 else { continue }
                files.append(
                    JobFile(jobID: jobID, path: parts[2], status: .renamed, oldPath: parts[1])
                )
            case "C":
                guard parts.count >= 3 else { continue }
                files.append(JobFile(jobID: jobID, path: parts[2], status: .added))
            default:
                continue
            }
        }
        return files
    }
}

struct GitRunner: Sendable {
    var workspace: URL
    var deadline: Date
    var home: URL

    init(workspace: URL, deadline: Date) {
        self.workspace = workspace
        self.deadline = deadline
        self.home = workspace.appendingPathComponent(".gegenlesen/.git-home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            throw IdentifyError.timeout
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        var gitArgs = [
            "-c", "user.name=gegenlesen",
            "-c", "user.email=gegenlesen@localhost",
            "-c", "init.defaultBranch=main",
            "-c", "safe.directory=*",
            "-c", "core.hooksPath=/nonexistent",
            "-c", "core.fsmonitor=",
            "-c", "core.pager=cat",
            "-c", "init.templateDir=",
        ]
        if arguments.first == "init" {
            gitArgs.append(contentsOf: ["init", "--template="])
            gitArgs.append(contentsOf: arguments.dropFirst())
        } else {
            gitArgs.append(contentsOf: arguments)
        }
        process.arguments = gitArgs
        process.currentDirectoryURL = workspace
        process.environment = GitRunner.isolatedEnvironment(home: home.path)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        try process.run()

        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        let timeout = DispatchTime.now() + remaining
        if group.wait(timeout: timeout) == .timedOut {
            process.terminate()
            throw IdentifyError.timeout
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw IdentifyError(errorMessage: err.isEmpty ? "git failed" : err)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func isolatedEnvironment(home: String = "/var/empty") -> [String: String] {
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": home,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_AUTHOR_NAME": "gegenlesen",
            "GIT_AUTHOR_EMAIL": "gegenlesen@localhost",
            "GIT_COMMITTER_NAME": "gegenlesen",
            "GIT_COMMITTER_EMAIL": "gegenlesen@localhost",
        ]
        let host = ProcessInfo.processInfo.environment
        for key in ["DEVELOPER_DIR", "SDKROOT"] {
            if let value = host[key], !value.isEmpty {
                env[key] = value
            }
        }
        return env
    }
}
