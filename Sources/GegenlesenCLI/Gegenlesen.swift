import ArgumentParser
import Foundation
import GegenlesenCore

@main
struct Gegenlesen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gegenlesen",
        abstract: "Pack a repo and start a gegenlesen review",
        subcommands: [Review.self, Harvest.self, Status.self, Cancel.self, Serve.self]
    )
}

enum ReviewFormat: String, ExpressibleByArgument {
    case text, json, markdown
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

    @Flag(name: .long, help: "Exit 1 unless the job succeeded with risk verdict auto_approve.")
    var requireAutoApprove = false

    @Option(name: .long, help: "stdout: text (default), json, or markdown.")
    var format: ReviewFormat = .text

    @Option(name: .long, help: "Seconds to wait for the job. Default 1800.")
    var timeout: Int = 1800

    @Option(name: .long, help: "Max findings in json/markdown output. Default 10.")
    var maxFindings: Int = GitHubReviewReport.defaultMaxFindings

    @Option(name: .long, help: "Ledger job URL baked into json/markdown when it is not loopback.")
    var ledgerURL: String?

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
        if format == .text {
            print(accepted.id)
        } else {
            eprint(accepted.id)
        }
        let terminal = try await client.poll(id: accepted.id, timeout: TimeInterval(max(timeout, 1)))
        let report = makeReport(terminal, client: client)
        switch format {
        case .text:
            printText(terminal)
        case .json:
            FileHandle.standardOutput.write(try report.jsonData())
            FileHandle.standardOutput.write(Data("\n".utf8))
        case .markdown:
            print(report.markdown)
        }
        if terminal.status == "failed" || terminal.status == "cancelled" {
            throw ExitCode(1)
        }
        if requireAutoApprove, terminal.risk?.verdict != "auto_approve" {
            throw ExitCode(1)
        }
    }

    private func makeReport(_ job: JobJSON, client: GegenlesenClient) -> GitHubReviewReport {
        let ledger = ledgerURL ?? client.baseURL.appendingPathComponent("jobs/\(job.id)").absoluteString
        let risk = job.risk.map {
            GitHubReviewReport.RiskSnapshot(
                verdict: $0.verdict,
                mode: $0.mode,
                score: $0.score ?? 0,
                appetite: $0.appetite ?? 0,
                reasons: $0.reasons.map {
                    GitHubReviewReport.ReasonSnapshot(code: $0.code, detail: $0.detail, points: $0.points)
                }
            )
        }
        return GitHubReviewReport.make(
            jobID: job.id,
            status: job.status,
            headSHA: job.headSHA,
            baseSHA: job.baseSHA,
            repository: job.repository,
            ledgerURL: ledger,
            risk: risk,
            findings: job.findings.map {
                GitHubReviewReport.FindingSnapshot(
                    severity: $0.judgeSeverity ?? $0.severity,
                    title: $0.title,
                    message: $0.message,
                    filePath: $0.filePath,
                    startLine: $0.startLine,
                    endLine: $0.endLine,
                    judgeVerdict: $0.judgeVerdict,
                    lifecycle: $0.lifecycle
                )
            },
            maxFindings: maxFindings
        )
    }

    private func printText(_ terminal: JobJSON) {
        if let error = terminal.errorMessage, !error.isEmpty {
            print("\(terminal.status) \(error)")
        } else {
            print(terminal.status)
        }
        if let risk = terminal.risk {
            print("risk \(risk.verdict) score \(risk.score ?? 0)/\(risk.appetite ?? 0) \(risk.mode)")
            for reason in risk.reasons {
                let points = reason.points.map { " \($0 > 0 ? "+" : "")\($0)" } ?? ""
                print("  \(reason.code)\(points)  \(reason.detail)")
            }
        }
    }
}

func eprint(_ string: String) {
    FileHandle.standardError.write(Data((string + "\n").utf8))
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
        let risk = job.risk.map { "  \($0.verdict)" } ?? ""
        print("\(job.id)  \(job.status)\(risk)  \(job.title ?? "-")  \(repo)  \(sha)\(err)")
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
