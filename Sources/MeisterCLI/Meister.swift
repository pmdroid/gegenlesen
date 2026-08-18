import ArgumentParser
import Foundation

@main
struct Meister: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meister",
        abstract: "Pack a repo and start a Meister review",
        subcommands: [Review.self, Status.self, Cancel.self, Serve.self]
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
        let client = MeisterClient()
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

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show one job or the latest jobs"
    )

    @Argument(help: "Job id (optional).")
    var id: String?

    func run() async throws {
        let client = MeisterClient()
        if let id {
            let job = try await client.job(id: id)
            printJob(job)
            return
        }
        let list = try await client.jobs()
        if list.jobs.isEmpty {
            print("No jobs yet. In a repo run `meister review`.")
            return
        }
        for job in list.jobs {
            printJob(job)
        }
    }

    private func printJob(_ job: JobJSON) {
        let sha = job.headSHA ?? job.baseSHA ?? "-"
        let err = job.errorMessage.map { " \($0)" } ?? ""
        print("\(job.id)  \(job.status)  \(job.title ?? "-")  \(sha)\(err)")
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
        let job = try await MeisterClient().cancel(id: id)
        print("\(job.id) \(job.status)")
    }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the Meister API if MeisterAPI is available"
    )

    func run() throws {
        let fm = FileManager.default
        let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let sibling = here.appendingPathComponent("MeisterAPI")
        if fm.isExecutableFile(atPath: sibling.path) {
            let process = Process()
            process.executableURL = sibling
            process.arguments = Array(CommandLine.arguments.dropFirst())
            try process.run()
            process.waitUntilExit()
            throw ExitCode(process.terminationStatus)
        }
        print("Start the API with: swift run MeisterAPI serve")
    }
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
