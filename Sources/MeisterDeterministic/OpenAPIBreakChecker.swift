import Foundation
import MeisterCore

public struct OpenAPIBreakChecker: DeterministicChecker {
    public init() {}

    public func check(file: JobFile, bytes: Data, workspace: Workspace, rule: Rule) throws -> [FindingDraft] {
        []
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