import Foundation
import Testing
@testable import GegenlesenAgent
@testable import GegenlesenCore

@Suite
struct EngineHostCredentialsTests {
    @Test
    func detectsClaudeOAuthAndApiKeyIndependently() throws {
        let home = try tempHome()
        try writeJSON(["claudeAiOauth": ["accessToken": "x"]], at: home, relative: ".claude/.credentials.json")

        let oauthOnly = EngineHostCredentials.probeEngine(
            engine: AgentEngineID.claude,
            home: home,
            providerEnv: [:]
        )
        #expect(oauthOnly.cliLogin)
        #expect(!oauthOnly.apiKey)
        #expect(oauthOnly.configured)

        let both = EngineHostCredentials.probeEngine(
            engine: AgentEngineID.claude,
            home: home,
            providerEnv: ["ANTHROPIC_API_KEY": "sk-ant-test"]
        )
        #expect(both.cliLogin)
        #expect(both.apiKey)
    }

    @Test
    func mountsClaudeCredentialsWhenOAuthPresent() throws {
        let home = try tempHome()
        try writeJSON(["claudeAiOauth": ["accessToken": "x"]], at: home, relative: ".claude/.credentials.json")

        let isolation = EngineHostCredentials.engineIsolation(
            engine: AgentEngineID.claude,
            homeDirectory: home,
            providerEnv: [:]
        )
        #expect(isolation.credentialBinds.count == 1)
        #expect(isolation.credentialBinds[0].dest == "/home/gegenlesen/.claude")
        #expect(!isolation.credentialBinds[0].readOnly)
        #expect(isolation.tmpfs.contains("/home/gegenlesen:rw,nosuid,nodev,uid=1000,gid=1000,size=512m"))
    }

    @Test
    func codexOAuthDoesNotRequireEnvKey() throws {
        let home = try tempHome()
        try writeJSON(
            ["auth_mode": "oauth", "tokens": ["access_token": "x"]],
            at: home,
            relative: ".codex/auth.json"
        )

        let status = EngineHostCredentials.probeEngine(
            engine: AgentEngineID.codex,
            home: home,
            providerEnv: [:]
        )
        #expect(status.cliLogin)
        #expect(!status.apiKey)
        #expect(status.configured)

        let isolation = EngineHostCredentials.engineIsolation(
            engine: AgentEngineID.codex,
            homeDirectory: home,
            providerEnv: [:]
        )
        #expect(isolation.credentialBinds.count == 1)
        #expect(isolation.credentialBinds[0].dest == "/home/gegenlesen/.codex/auth.json")
    }

    @Test
    func mountsCursorCliConfigWhenPresent() throws {
        let home = try tempHome()
        try writeJSON(["version": 1], at: home, relative: ".cursor/cli-config.json")

        let isolation = EngineHostCredentials.engineIsolation(
            engine: AgentEngineID.cursorAgent,
            homeDirectory: home,
            providerEnv: [:]
        )
        #expect(isolation.credentialBinds.contains(where: { $0.dest == "/home/gegenlesen/.cursor" && !$0.readOnly }))
        #expect(!isolation.tmpfs.contains(where: { $0.hasPrefix("/home/gegenlesen/.cursor:") }))
    }

    @Test
    func cursorAcceptsEnvKeyOrSdkLogin() throws {
        let home = try tempHome()
        try writeJSON(["apiKey": "ck-test"], at: home, relative: ".cursor/sdk/auth.json")

        let fromLogin = EngineHostCredentials.probeEngine(
            engine: AgentEngineID.cursorAgent,
            home: home,
            providerEnv: [:]
        )
        #expect(fromLogin.cliLogin)
        #expect(!fromLogin.apiKey)

        let fromEnv = EngineHostCredentials.probeEngine(
            engine: AgentEngineID.cursorAgent,
            home: home,
            providerEnv: ["CURSOR_API_KEY": "ck-test"]
        )
        #expect(fromEnv.apiKey)
    }

    @Test
    func mountsGrokDirectoryWhenAuthPresent() throws {
        let home = try tempHome()
        try writeJSON(["accessToken": "x"], at: home, relative: ".grok/auth.json")

        let isolation = EngineHostCredentials.engineIsolation(
            engine: AgentEngineID.grok,
            homeDirectory: home,
            providerEnv: [:]
        )
        #expect(isolation.credentialBinds.count == 1)
        #expect(isolation.credentialBinds[0].dest == "/home/gegenlesen/.grok")
        #expect(!isolation.credentialBinds[0].readOnly)
        #expect(!isolation.tmpfs.contains(where: { $0.hasPrefix("/home/gegenlesen/.grok:") }))
    }

    private func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gegenlesen-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJSON(_ object: [String: Any], at home: URL, relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
    }
}
