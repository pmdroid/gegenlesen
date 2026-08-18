import Foundation
import MeisterCore

public struct OpenAPIBreakChecker: DeterministicChecker {
    public init() {}

    public func check(file: JobFile, bytes: Data, workspace: Workspace, rule: Rule) throws -> [FindingDraft] {
        []
    }

    /// Same isolation as `command` (no keys, `--network none`, 20s).
    public static func sandboxRequest(
        jobID: JobID,
        ruleID: RuleID,
        workspace: URL,
        image: String,
        argv: [String],
        timeout: Duration = .seconds(20)
    ) -> DockerRequest {
        CommandChecker.sandboxRequest(
            name: ReviewContainers.command(jobID, ruleID),
            workspace: workspace,
            image: image,
            argv: argv,
            timeout: timeout
        )
    }

    public static func binaryAvailable() -> Bool {
        let fm = FileManager.default
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("oasdiff")
            if fm.isExecutableFile(atPath: candidate.path) {
                return true
            }
        }
        return false
    }
}