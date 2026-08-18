import Foundation
@testable import MeisterCore

func repoRootFromAgentTests() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func withTempDir(_ prefix: String, _ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

func withTempDir(_ prefix: String, _ body: (URL) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}

func writeFile(_ relative: String, _ contents: String, in root: URL) throws {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

func dockerBinary() -> String? {
    for path in ["/usr/local/bin/docker", "/usr/bin/docker", "/opt/homebrew/bin/docker"] {
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
    }
    return nil
}

func runnerImagePresent(image: String = "meister/opencode-runner:0.1.0") -> Bool {
    guard let docker = dockerBinary() else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: docker)
    process.arguments = ["image", "inspect", image]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin", "HOME": NSTemporaryDirectory()]
    do {
        try process.run()
    } catch {
        return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

func sampleJob(id: JobID = JobID.generate()) -> Job {
    let now = Date()
    return Job(
        id: id,
        createdAt: now,
        updatedAt: now,
        status: .reviewing,
        scope: .full,
        reviewerAModelID: "anthropic/claude-sonnet-4-5",
        reviewerBModelID: "openai/gpt-5.2",
        judgeModelID: "anthropic/claude-sonnet-4-5"
    )
}
