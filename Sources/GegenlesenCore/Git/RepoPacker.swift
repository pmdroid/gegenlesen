import Foundation

public enum RepoPackError: Error, CustomStringConvertible, Sendable {
    case gitFailed(String)
    case emptyChangeSet
    case missingDiff
    case notARepository

    public var description: String {
        switch self {
        case .gitFailed(let message):
            return message.isEmpty ? "git failed" : message
        case .emptyChangeSet:
            return "empty diff and no usable bundle"
        case .missingDiff:
            return "git diff did not produce .gegenlesen/diff.patch"
        case .notARepository:
            return "not a git repository"
        }
    }
}

public struct RepoPackResult: Sendable {
    public var archive: Data
    public var base: String
    public var head: String
    public var droppedBundle: Bool
    /// How the base was chosen, e.g. "explicit_ref", "merge_base:origin/main".
    public var baseSource: String?

    public init(archive: Data, base: String, head: String, droppedBundle: Bool, baseSource: String? = nil) {
        self.archive = archive
        self.base = base
        self.head = head
        self.droppedBundle = droppedBundle
        self.baseSource = baseSource
    }
}

public struct ResolvedBase: Sendable, Equatable {
    public var sha: String
    public var source: String

    public init(sha: String, source: String) {
        self.sha = sha
        self.source = source
    }
}

public enum RepoPacker: Sendable {
    public static let maxBundleBytes = 40 * 1024 * 1024

    public static func resolveHead(cwd: URL) throws -> String {
        try gitOutput(["rev-parse", "HEAD"], cwd: cwd).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func resolveBase(cwd: URL, ref: String?) throws -> ResolvedBase {
        if let ref, !ref.isEmpty {
            fetchRef(ref, cwd: cwd)
            for candidate in remoteAndLocal(ref) {
                if let sha = try? gitOutput(["rev-parse", candidate], cwd: cwd)
                    .trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty {
                    return ResolvedBase(sha: sha, source: "explicit_ref:\(ref)")
                }
            }
        }
        for name in ["main", "master", "trunk"] {
            // A stale remote-tracking ref (or stale local main) in a throwaway
            // worktree silently widens the pack to an ancient merge-base;
            // fetch the upstream copy first and prefer it.
            fetchRef(name, cwd: cwd)
            if let sha = try? gitOutput(["merge-base", "origin/\(name)", "HEAD"], cwd: cwd)
                .trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty {
                return ResolvedBase(sha: sha, source: "merge_base:origin/\(name)")
            }
            if let sha = try? gitOutput(["merge-base", name, "HEAD"], cwd: cwd)
                .trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty {
                return ResolvedBase(sha: sha, source: "merge_base:\(name)")
            }
        }
        if let sha = try? gitOutput(["rev-parse", "HEAD^"], cwd: cwd)
            .trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty {
            return ResolvedBase(sha: sha, source: "parent_of_head")
        }
        if let sha = try? gitOutput(["rev-parse", "HEAD"], cwd: cwd)
            .trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty {
            return ResolvedBase(sha: sha, source: "head")
        }
        throw RepoPackError.gitFailed("could not resolve pack base")
    }

    /// Best-effort `git fetch origin <ref>`; SHAs and refs/ paths are skipped.
    private static func fetchRef(_ ref: String, cwd: URL) {
        let name = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !name.hasPrefix("refs/"),
              name.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) == nil
        else {
            return
        }
        _ = try? git(["fetch", "--quiet", "--no-tags", "origin", name], cwd: cwd)
    }

    private static func remoteAndLocal(_ ref: String) -> [String] {
        if ref.hasPrefix("origin/") {
            return [ref, String(ref.dropFirst("origin/".count))]
        }
        return ["origin/\(ref)", ref]
    }

    public static func originURL(cwd: URL) -> String? {
        guard let raw = try? gitOutput(["remote", "get-url", "origin"], cwd: cwd) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func pack(
        cwd: URL,
        base: String,
        head: String,
        maxBundleBytes: Int = maxBundleBytes,
        baseSource: String? = nil
    ) throws -> RepoPackResult {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(
            "gegenlesen-pack-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let archiveTar = work.appendingPathComponent("head.tar")
        let staging = work.appendingPathComponent("tree", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try git(
            ["archive", "--format=tar", "--output", archiveTar.path, head],
            cwd: cwd
        )
        _ = try run(
            "/usr/bin/tar",
            ["-xf", archiveTar.path, "-C", staging.path],
            cwd: staging
        )
        try? fm.removeItem(at: archiveTar)

        let meta = staging.appendingPathComponent(".gegenlesen", isDirectory: true)
        try fm.createDirectory(at: meta, withIntermediateDirectories: true)
        try Data(base.utf8).write(to: meta.appendingPathComponent("base_sha"))
        try Data(head.utf8).write(to: meta.appendingPathComponent("head_sha"))
        if let origin = originURL(cwd: cwd) {
            try Data(origin.utf8).write(to: meta.appendingPathComponent("repository"))
        }

        let diffURL = meta.appendingPathComponent("diff.patch")
        try git(
            ["diff", "--no-color", "--find-renames", base, head],
            cwd: cwd,
            stdoutFile: diffURL
        )
        guard fm.fileExists(atPath: diffURL.path) else {
            throw RepoPackError.missingDiff
        }

        let bundleURL = meta.appendingPathComponent("history.bundle")
        var droppedBundle = false
        let packRefs = "refs/gegenlesen/pack-\(UUID().uuidString)"
        let baseRef = "\(packRefs)/base"
        let headRef = "\(packRefs)/head"
        do {
            try git(["update-ref", baseRef, base], cwd: cwd)
            try git(["update-ref", headRef, head], cwd: cwd)
            try git(["bundle", "create", bundleURL.path, baseRef, headRef], cwd: cwd)
            let attrs = try fm.attributesOfItem(atPath: bundleURL.path)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            if size > maxBundleBytes {
                try? fm.removeItem(at: bundleURL)
                droppedBundle = true
            }
        } catch {
            try? fm.removeItem(at: bundleURL)
        }
        try? git(["update-ref", "-d", baseRef], cwd: cwd)
        try? git(["update-ref", "-d", headRef], cwd: cwd)

        let diffSize = (try? fm.attributesOfItem(atPath: diffURL.path)[.size] as? NSNumber)?.intValue ?? 0
        let hasBundle = fm.fileExists(atPath: bundleURL.path)
        if diffSize == 0, !hasBundle, base != head {
            throw RepoPackError.emptyChangeSet
        }

        let outTar = work.appendingPathComponent("change.tar.gz")
        _ = try run(
            "/usr/bin/tar",
            [
                "-czf", outTar.path,
                "--exclude=node_modules",
                "--exclude=.build",
                "--exclude=dist",
                "--exclude=target",
                "--exclude=var",
                "-C", staging.path,
                ".",
            ],
            cwd: staging,
            extraEnv: ["COPYFILE_DISABLE": "1"]
        )
        let archive = try Data(contentsOf: outTar)
        return RepoPackResult(
            archive: archive,
            base: base,
            head: head,
            droppedBundle: droppedBundle,
            baseSource: baseSource
        )
    }

    private static func git(
        _ arguments: [String],
        cwd: URL,
        stdoutFile: URL? = nil
    ) throws {
        _ = try gitOutput(arguments, cwd: cwd, stdoutFile: stdoutFile)
    }

    private static func gitOutput(
        _ arguments: [String],
        cwd: URL,
        stdoutFile: URL? = nil
    ) throws -> String {
        let result = try run(
            "/usr/bin/git",
            [
                "-c", "safe.directory=*",
                "-c", "core.pager=cat",
            ] + arguments,
            cwd: cwd,
            stdoutFile: stdoutFile
        )
        if result.status != 0 {
            let err = String(data: result.stderr, encoding: .utf8) ?? ""
            throw RepoPackError.gitFailed(err.isEmpty ? "git \(arguments.first ?? "") failed" : err)
        }
        if stdoutFile != nil {
            return ""
        }
        return String(data: result.stdout, encoding: .utf8) ?? ""
    }

    private static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: URL,
        stdoutFile: URL? = nil,
        extraEnv: [String: String] = [:]
    ) throws -> (stdout: Data, stderr: Data, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var env = GitRunner.isolatedEnvironment(
            home: cwd.appendingPathComponent(".gegenlesen-pack-home").path
        )
        extraEnv.forEach { env[$0.key] = $0.value }
        process.environment = env
        let stderr = Pipe()
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe: Pipe?
        if let stdoutFile {
            FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: stdoutFile)
            stdoutPipe = nil
        } else {
            let pipe = Pipe()
            process.standardOutput = pipe
            stdoutPipe = pipe
        }
        try process.run()
        let stdout = stdoutPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        return (
            stdout,
            stderr.fileHandleForReading.readDataToEndOfFile(),
            process.terminationStatus
        )
    }
}
