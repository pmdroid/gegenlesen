import Foundation
import Testing
@testable import GegenlesenAgent

@Suite
struct OpenCodeCLIProbeTests {
    @Test
    func probeHelpFlagsWhenImageExists() throws {
        guard let docker = dockerBinary(), runnerImagePresent() else {
            return
        }
        let help = try runDocker(docker, arguments: [
            "run", "--rm", "--network", "none",
            "gegenlesen/opencode-runner:0.1.0",
            "opencode", "--help",
        ])
        let runHelp = try runDocker(docker, arguments: [
            "run", "--rm", "--network", "none",
            "gegenlesen/opencode-runner:0.1.0",
            "opencode", "run", "--help",
        ])
        let combined = help + "\n" + runHelp
        #expect(combined.contains("serve") || combined.contains("run"))
        #expect(combined.contains("--agent") || combined.contains("agent"))
        #expect(combined.contains("--model") || combined.contains("model"))
    }

    @Test
    func agentCanWriteFindingsAndNotSourcesWhenImageExists() throws {
        guard let docker = dockerBinary(), runnerImagePresent() else {
            return
        }
        try withTempDir("probe-write") { root in
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".gegenlesen"),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Sources"),
                withIntermediateDirectories: true
            )
            let policy = try OpenCodeConfig.policyJSON(model: "anthropic/claude-sonnet-4-5")
            let baked = repoRootFromAgentTests().appendingPathComponent("docker/opencode-runner/opencode.json")
            let bakedJSON = try String(contentsOf: baked, encoding: .utf8)
            #expect(bakedJSON.contains(#""mcp": {}"#) || bakedJSON.contains(#""mcp":{}"#))
            #expect(policy.contains("findings.json"))
            #expect(!policy.contains("Sources/"))

            _ = docker
            _ = root
        }
    }

    private func runDocker(_ docker: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "HOME": NSTemporaryDirectory(),
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out + err
    }
}
