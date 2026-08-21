import ArgumentParser
import Foundation

@main
struct Gegenlesen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gegenlesen",
        abstract: "Pack a repo and start a gegenlesen review",
        subcommands: [Review.self, Harvest.self, Status.self, Cancel.self, Serve.self, ScannerTest.self]
    )
}

struct Review: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review",
        abstract: "Pack the current repo and POST a review job"
    )

    @Argument(help: "Base ref for pack-repo.sh (optional).")
    var baseRef: String?

    @Option(name: .long, help: "Parent job id for an incremental review.")
    var parent: String?

    func run() async throws {
        let client = GegenlesenClient()
        let archive = try packCWD(baseRef: baseRef)
        var meta: [String: Any] = [
            "scope": parent == nil ? "full" : "incremental",
        ]
        if let parent {
            meta["parent_job_id"] = parent
        }
        if let baseRef {
            meta["base_ref"] = baseRef
        }
        if let repository = detectRepository() {
            meta["repository"] = repository
        }
        let accepted = try await client.createJob(archive: archive, meta: meta)
        print(accepted.id)
        let terminal = try await client.poll(id: accepted.id)
        if let error = terminal.errorMessage, !error.isEmpty {
            print("\(terminal.status) \(error)")
        } else {
            print(terminal.status)
        }
        if terminal.status == "failed" || terminal.status == "cancelled" {
            throw ExitCode(1)
        }
    }
}

struct Harvest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "harvest",
        abstract: "Pack the current repo and mine disabled house-rule drafts"
    )

    func run() async throws {
        let client = GegenlesenClient()
        let archive = try packCWD(baseRef: nil)
        let accepted = try await client.createHarvest(archive: archive, repository: detectRepository())
        print(accepted.id)
        let terminal = try await client.poll(id: accepted.id, timeout: 900)
        if let error = terminal.errorMessage, !error.isEmpty {
            print("\(terminal.status) \(error)")
        } else {
            print(terminal.status)
        }
        if terminal.status == "failed" || terminal.status == "cancelled" {
            throw ExitCode(1)
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show one job or the latest jobs"
    )

    @Argument(help: "Job id (optional).")
    var id: String?

    func run() async throws {
        let client = GegenlesenClient()
        if let id {
            let job = try await client.job(id: id)
            printJob(job)
            return
        }
        let list = try await client.jobs()
        if list.jobs.isEmpty {
            print("No jobs yet. In a repo run `gegenlesen review`.")
            return
        }
        for job in list.jobs {
            printJob(job)
        }
    }

    private func printJob(_ job: JobJSON) {
        let sha = job.headSHA ?? job.baseSHA ?? "-"
        let repo = job.repository ?? "-"
        let err = job.errorMessage.map { " \($0)" } ?? ""
        print("\(job.id)  \(job.status)  \(job.title ?? "-")  \(repo)  \(sha)\(err)")
    }
}

struct Cancel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "Cancel a queued or running job"
    )

    @Argument(help: "Job id.")
    var id: String

    func run() async throws {
        let job = try await GegenlesenClient().cancel(id: id)
        print("\(job.id) \(job.status)")
    }
}

struct ScannerTest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scanner-test",
        abstract: "Run a scanner image against the bundled fixture and check JSONL"
    )

    @Option(name: .long, help: "Scanner image (default gegenlesen/scanner:0.1.0).")
    var image: String = "gegenlesen/scanner:0.1.0"

    func run() async throws {
        let fixture = findScannerFixture()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolveDocker())
        process.arguments = [
            "run", "--rm",
            "--network", "bridge",
            "--read-only",
            "--user", "1000:1000",
            "--workdir", "/workspace",
            "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,uid=1000,gid=1000,size=256m",
            "--mount", "type=bind,src=\(fixture.path),dst=/workspace,readonly",
            "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges",
            "-e", "HOME=/tmp",
            "-e", "PATH=/usr/local/bin:/usr/bin:/bin",
            image,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            FileHandle.standardError.write(Data("scanner-test: docker exit \(process.terminationStatus)\n\(err)".utf8))
            throw ExitCode(1)
        }
        var count = 0
        for line in out.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
                FileHandle.standardError.write(Data("scanner-test: invalid JSONL: \(trimmed)\n".utf8))
                throw ExitCode(1)
            }
            for key in ["title", "message", "severity", "file_path", "snippet"] {
                guard let value = object[key] as? String, !value.isEmpty else {
                    FileHandle.standardError.write(Data("scanner-test: missing \(key)\n".utf8))
                    throw ExitCode(1)
                }
            }
            if object["file_path"] as? String == "evals/cases/no-hardcoded-secrets/head/Sources/Config.swift" {
                FileHandle.standardError.write(Data("scanner-test: planted eval secret leaked\n".utf8))
                throw ExitCode(1)
            }
            count += 1
        }
        print("ok \(count) findings from \(image)")
    }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the gegenlesen API if GegenlesenAPI is available"
    )

    func run() throws {
        let fm = FileManager.default
        let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let sibling = here.appendingPathComponent("GegenlesenAPI")
        if fm.isExecutableFile(atPath: sibling.path) {
            let process = Process()
            process.executableURL = sibling
            process.arguments = Array(CommandLine.arguments.dropFirst())
            try process.run()
            process.waitUntilExit()
            throw ExitCode(process.terminationStatus)
        }
        print("Start the API with: swift run GegenlesenAPI serve")
    }
}

func detectRepository() -> String? {
    if let remote = gitOriginURL() {
        return normalizeRepository(remote)
    }
    return normalizeRepository(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent)
}

func gitOriginURL() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["remote", "get-url", "origin"]
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
}

func normalizeRepository(_ raw: String?) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    if value.hasPrefix("git@") {
        let rest = String(value.dropFirst(4))
        if let colon = rest.firstIndex(of: ":") {
            value = String(rest[..<colon]) + "/" + String(rest[rest.index(after: colon)...])
        }
    } else if let url = URL(string: value), let host = url.host, !host.isEmpty {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        value = path.isEmpty ? host : "\(host)/\(path)"
    }
    if value.hasSuffix(".git") {
        value = String(value.dropLast(4))
    }
    while value.hasSuffix("/") {
        value.removeLast()
    }
    return value.isEmpty ? nil : value
}

func resolveDocker() -> String {
    let fm = FileManager.default
    if let override = ProcessInfo.processInfo.environment["GEGENLESEN_DOCKER"], !override.isEmpty {
        return override
    }
    for path in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"] {
        if fm.isExecutableFile(atPath: path) { return path }
    }
    return "/usr/bin/docker"
}

func findScannerFixture() -> URL {
    let fm = FileManager.default
    let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
    let candidates = [
        cwd.appendingPathComponent("docker/scanner/fixtures"),
        here.appendingPathComponent("docker/scanner/fixtures"),
        here.deletingLastPathComponent().appendingPathComponent("docker/scanner/fixtures"),
    ]
    for url in candidates where fm.fileExists(atPath: url.path) {
        return url
    }
    return cwd.appendingPathComponent("docker/scanner/fixtures")
}

func packCWD(baseRef: String?) throws -> Data {
    let script = findPackScript()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    var arguments = [script.path]
    if let baseRef {
        arguments.append(baseRef)
    }
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    try process.run()
    // Drain stdout before waitUntilExit. A multi-MB tarball fills the pipe
    // (~64 KiB) and pack-repo.sh blocks forever if we wait first.
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw CLIError("pack-repo.sh failed: \(err)")
    }
    return data
}

func findPackScript() -> URL {
    let fm = FileManager.default
    var candidates: [URL] = []
    if let root = ProcessInfo.processInfo.environment["GEGENLESEN_ROOT"], !root.isEmpty {
        candidates.append(URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("scripts/pack-repo.sh"))
    }
    if let exeDir = resolvedCLIDirectory() {
        candidates.append(exeDir.appendingPathComponent("scripts/pack-repo.sh"))
    }
    var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
    for _ in 0..<8 {
        candidates.append(dir.appendingPathComponent("scripts/pack-repo.sh"))
        dir.deleteLastPathComponent()
    }
    for candidate in candidates where fm.isReadableFile(atPath: candidate.path) {
        return candidate
    }
    return URL(fileURLWithPath: "scripts/pack-repo.sh")
}

func resolvedCLIDirectory() -> URL? {
    var path = CommandLine.arguments[0]
    let fm = FileManager.default
    if !path.contains("/") {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir), isDirectory: true).appendingPathComponent(path)
            if fm.isExecutableFile(atPath: candidate.path) {
                path = candidate.path
                break
            }
        }
    }
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    guard url.path != "/" else { return nil }
    return url.deletingLastPathComponent()
}

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
