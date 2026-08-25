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

    @Test
    func overlayPrefersRepoOverride() throws {
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
        try "global reviewer".write(
            to: data.appendingPathComponent("agents/reviewer.md"),
            atomically: true,
            encoding: .utf8
        )
        let key = try #require(AgentCatalog.repoKey("github.com/acme/app"))
        let repoDir = data.appendingPathComponent("agents/repos/\(key)")
        try fm.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try "repo reviewer".write(
            to: repoDir.appendingPathComponent("reviewer.md"),
            atomically: true,
            encoding: .utf8
        )

        let dest = try materializeRunnerConfig(
            workingDirectory: wd.path,
            dataDir: data.path,
            fileManager: fm
        )
        let globalOverlay = try String(
            contentsOf: dest.appendingPathComponent("agents/reviewer.md"),
            encoding: .utf8
        )
        #expect(globalOverlay == "global reviewer")

        try overlayCustomAgents(
            dataDir: data.path,
            dest: dest,
            fileManager: fm,
            workingDirectory: wd.path,
            repository: "github.com/acme/app"
        )
        let repoOverlay = try String(
            contentsOf: dest.appendingPathComponent("agents/reviewer.md"),
            encoding: .utf8
        )
        #expect(repoOverlay == "repo reviewer")
    }
}
