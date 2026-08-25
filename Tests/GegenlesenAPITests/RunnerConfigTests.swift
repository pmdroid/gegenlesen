import Foundation
import Testing
@testable import GegenlesenAPI

@Suite
struct RunnerConfigTests {
    @Test
    func overrideEnvWins() throws {
        let url = try materializeRunnerConfig(
            workingDirectory: "/tmp/wd",
            dataDir: "/tmp/data",
            environment: ["GEGENLESEN_RUNNER_CONFIG": "/opt/runner"]
        )
        #expect(url.path == "/opt/runner")
    }

    @Test
    func copiesPackagedTreeIntoDataDir() throws {
        let fm = FileManager.default
        let wd = fm.temporaryDirectory.appendingPathComponent("gl-wd-\(UUID().uuidString)")
        let data = fm.temporaryDirectory.appendingPathComponent("gl-data-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: wd)
            try? fm.removeItem(at: data)
        }
        let packaged = wd.appendingPathComponent("docker/opencode-runner")
        try fm.createDirectory(at: packaged.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try "x".write(to: packaged.appendingPathComponent("opencode.json"), atomically: true, encoding: .utf8)

        let dest = try materializeRunnerConfig(
            workingDirectory: wd.path,
            dataDir: data.path,
            fileManager: fm
        )
        #expect(dest.path == data.appendingPathComponent("opencode-runner").path)
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("opencode.json").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("agents").path))
    }

    @Test
    func overlaysCustomAgentMarkdown() throws {
        let fm = FileManager.default
        let wd = fm.temporaryDirectory.appendingPathComponent("gl-wd-\(UUID().uuidString)")
        let data = fm.temporaryDirectory.appendingPathComponent("gl-data-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: wd)
            try? fm.removeItem(at: data)
        }
        let packaged = wd.appendingPathComponent("docker/opencode-runner")
        try fm.createDirectory(at: packaged.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try "x".write(to: packaged.appendingPathComponent("opencode.json"), atomically: true, encoding: .utf8)
        try "default reviewer".write(
            to: packaged.appendingPathComponent("agents/reviewer.md"),
            atomically: true,
            encoding: .utf8
        )
        try fm.createDirectory(at: data.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try "custom reviewer".write(
            to: data.appendingPathComponent("agents/reviewer.md"),
            atomically: true,
            encoding: .utf8
        )

        let dest = try materializeRunnerConfig(
            workingDirectory: wd.path,
            dataDir: data.path,
            fileManager: fm
        )
        let overlay = try String(
            contentsOf: dest.appendingPathComponent("agents/reviewer.md"),
            encoding: .utf8
        )
        #expect(overlay == "custom reviewer")
    }
}
