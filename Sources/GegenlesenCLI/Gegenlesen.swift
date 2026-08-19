import ArgumentParser
import Foundation

@main
struct Gegenlesen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gegenlesen",
        abstract: "Pack a repo and start a gegenlesen review",
        subcommands: [Review.self, Harvest.self, Status.self, Cancel.self, Serve.self, Eval.self]
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
    process.waitUntilExit()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    if process.terminationStatus != 0 {
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw CLIError("pack-repo.sh failed: \(err)")
    }
    return data
}

func findPackScript() -> URL {
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<8 {
        let candidate = dir.appendingPathComponent("scripts/pack-repo.sh")
        if FileManager.default.isReadableFile(atPath: candidate.path) {
            return candidate
        }
        dir.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: "scripts/pack-repo.sh")
}

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
