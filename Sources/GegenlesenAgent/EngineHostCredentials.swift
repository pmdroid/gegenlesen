import Foundation
import GegenlesenCore

public struct EngineAuthStatus: Sendable, Equatable, Codable {
    public var configured: Bool
    public var apiKey: Bool
    public var cliLogin: Bool

    public init(configured: Bool, apiKey: Bool, cliLogin: Bool) {
        self.configured = configured
        self.apiKey = apiKey
        self.cliLogin = cliLogin
    }

    public init(apiKey: Bool, cliLogin: Bool) {
        self.apiKey = apiKey
        self.cliLogin = cliLogin
        self.configured = apiKey || cliLogin
    }

    enum CodingKeys: String, CodingKey {
        case configured
        case apiKey = "api_key"
        case cliLogin = "cli_login"
    }
}

public enum EngineHostCredentials {
    public static func hostHomeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["GEGENLESEN_HOST_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static func probeAll(
        homeDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: EngineAuthStatus] {
        let home = homeDirectory ?? hostHomeDirectory(environment: environment)
        return [
            AgentEngineID.opencode: probeOpenCode(environment: environment),
            AgentEngineID.claude: probeClaude(home: home, environment: environment),
            AgentEngineID.codex: probeCodex(home: home, environment: environment),
            AgentEngineID.cursorAgent: probeCursor(home: home, environment: environment),
            AgentEngineID.grok: probeGrok(home: home, environment: environment),
        ]
    }

    public static func enrichedProviderEnv(
        engine: String,
        homeDirectory: URL? = nil,
        providerEnv: [String: String]
    ) -> [String: String] {
        var env = providerEnv
        guard engine == AgentEngineID.cursorAgent else { return env }
        if nonEmpty(env["CURSOR_API_KEY"]) != nil || nonEmpty(env["CURSOR_AUTH_TOKEN"]) != nil {
            return env
        }
        #if os(macOS)
        if let token = readCursorKeychainAccessToken() {
            env["CURSOR_AUTH_TOKEN"] = token
        }
        #endif
        _ = homeDirectory
        return env
    }

    public static func engineIsolation(
        engine: String,
        homeDirectory: URL? = nil,
        providerEnv: [String: String] = [:]
    ) -> (tmpfs: [String], credentialBinds: [DockerRequest.Bind]) {
        let home = homeDirectory ?? hostHomeDirectory()
        let status = probeEngine(engine: engine, home: home, providerEnv: providerEnv)
        var tmpfs = ACPEngines.engineTmpfs(engine: engine)
        var binds: [DockerRequest.Bind] = []
        guard status.configured else {
            return (tmpfs, binds)
        }

        switch engine {
        case AgentEngineID.claude:
            syncClaudeCredentialsForContainer(home: home)
            // Bind the whole ~/.claude dir so the container user can create debug/ logs.
            // A single-file bind creates a root-owned .claude parent and breaks session startup.
            if let bind = directoryBind(
                home: home,
                relative: ".claude",
                dest: "/home/gegenlesen/.claude",
                readOnly: false
            ) {
                binds.append(bind)
            }
        case AgentEngineID.codex:
            if let bind = fileBind(home: home, relative: ".codex/auth.json", dest: "/home/gegenlesen/.codex/auth.json") {
                binds.append(bind)
            }
        case AgentEngineID.cursorAgent:
            if let bind = directoryBind(
                home: home,
                relative: ".cursor",
                dest: "/home/gegenlesen/.cursor",
                readOnly: false
            ) {
                binds.append(bind)
                tmpfs.removeAll { $0.hasPrefix("/home/gegenlesen/.cursor:") }
            }
        case AgentEngineID.grok:
            if let bind = directoryBind(
                home: home,
                relative: ".grok",
                dest: "/home/gegenlesen/.grok",
                readOnly: false
            ) {
                binds.append(bind)
                tmpfs.removeAll { $0.hasPrefix("/home/gegenlesen/.grok:") }
            }
        default:
            break
        }
        return (tmpfs, binds)
    }

    static func probeEngine(
        engine: String,
        home: URL,
        providerEnv: [String: String]
    ) -> EngineAuthStatus {
        switch engine {
        case AgentEngineID.opencode:
            return probeOpenCode(environment: providerEnv)
        case AgentEngineID.claude:
            return probeClaude(home: home, environment: providerEnv)
        case AgentEngineID.codex:
            return probeCodex(home: home, environment: providerEnv)
        case AgentEngineID.cursorAgent:
            return probeCursor(home: home, environment: providerEnv)
        case AgentEngineID.grok:
            return probeGrok(home: home, environment: providerEnv)
        default:
            return EngineAuthStatus(apiKey: false, cliLogin: false)
        }
    }

    static func probeOpenCode(environment: [String: String]) -> EngineAuthStatus {
        let configured = nonEmpty(environment["OPENROUTER_API_KEY"]) != nil
        return EngineAuthStatus(apiKey: configured, cliLogin: false)
    }

    static func probeClaude(home: URL, environment: [String: String]) -> EngineAuthStatus {
        let apiKey = nonEmpty(environment["ANTHROPIC_API_KEY"]) != nil
        let cliLogin = claudeOAuthPresent(home: home)
        return EngineAuthStatus(apiKey: apiKey, cliLogin: cliLogin)
    }

    static func probeCodex(home: URL, environment: [String: String]) -> EngineAuthStatus {
        let apiKey = nonEmpty(environment["OPENAI_API_KEY"]) != nil
            || nonEmpty(environment["CODEX_API_KEY"]) != nil
        let auth = readJSONObject(home: home, relative: ".codex/auth.json")
        let fileKey = nonEmpty(auth?["OPENAI_API_KEY"] as? String) != nil
        let oauthTokens = auth?["tokens"] as? [String: Any]
        let cliLogin = oauthTokens?.isEmpty == false
        return EngineAuthStatus(apiKey: apiKey || fileKey, cliLogin: cliLogin)
    }

    static func probeCursor(home: URL, environment: [String: String]) -> EngineAuthStatus {
        let apiKey = nonEmpty(environment["CURSOR_API_KEY"]) != nil
            || nonEmpty(environment["CURSOR_AUTH_TOKEN"]) != nil
        let auth = readJSONObject(home: home, relative: ".cursor/sdk/auth.json")
        let sdkLogin = nonEmpty(auth?["apiKey"] as? String) != nil
            || nonEmpty(auth?["accessToken"] as? String) != nil
        let cliConfig = home.appendingPathComponent(".cursor/cli-config.json").path
        let hasCliConfig = FileManager.default.isReadableFile(atPath: cliConfig)
        let cliLogin = sdkLogin
            || hasCliConfig
            || EngineAgentPaths.cursorAgent(environment: environment, home: home) != nil
        return EngineAuthStatus(apiKey: apiKey, cliLogin: cliLogin)
    }

    static func probeGrok(home: URL, environment: [String: String]) -> EngineAuthStatus {
        let apiKey = nonEmpty(environment["XAI_API_KEY"]) != nil
            || nonEmpty(environment["GROK_API_KEY"]) != nil
        let auth = readJSONObject(home: home, relative: ".grok/auth.json")
        let cliLogin = auth?.isEmpty == false
        return EngineAuthStatus(apiKey: apiKey, cliLogin: cliLogin)
    }

    static func claudeOAuthPresent(home: URL) -> Bool {
        if claudeOAuthValid(home: home) {
            return true
        }
        #if os(macOS)
        return readClaudeKeychainOAuth() != nil
        #else
        return false
        #endif
    }

    static func claudeOAuthValid(home: URL) -> Bool {
        guard let root = readJSONObject(home: home, relative: ".claude/.credentials.json"),
              let oauth = root["claudeAiOauth"] as? [String: Any],
              !oauth.isEmpty else {
            return false
        }
        guard let expiresAt = oauth["expiresAt"] as? NSNumber else {
            return true
        }
        let millis = expiresAt.doubleValue
        let seconds = millis > 1_000_000_000_000 ? millis / 1000 : millis
        return Date().timeIntervalSince1970 < seconds
    }

    static func syncClaudeCredentialsForContainer(home: URL) {
        #if os(macOS)
        guard let oauth = readClaudeKeychainOAuth() else { return }
        let claudeDir = home.appendingPathComponent(".claude")
        let dest = claudeDir.appendingPathComponent(".credentials.json")
        do {
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: claudeDir.appendingPathComponent("debug"),
                withIntermediateDirectories: true
            )
            let payload: [String: Any] = ["claudeAiOauth": oauth]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: dest, options: .atomic)
        } catch {}
        #endif
    }

    #if os(macOS)
    static func readCursorKeychainAccessToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "cursor-access-token",
            "-a", "cursor-user",
            "-w",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let token = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return nonEmpty(token)
    }

    static func readClaudeKeychainOAuth() -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let oauth = object["claudeAiOauth"] as? [String: Any], !oauth.isEmpty {
            return oauth
        }
        if object["accessToken"] != nil {
            return object
        }
        return nil
    }
    #endif

    static func fileBind(home: URL, relative: String, dest: String, readOnly: Bool = true) -> DockerRequest.Bind? {
        let source = home.appendingPathComponent(relative).path
        guard FileManager.default.isReadableFile(atPath: source) else { return nil }
        return DockerRequest.Bind(source: source, dest: dest, readOnly: readOnly)
    }

    static func directoryBind(home: URL, relative: String, dest: String, readOnly: Bool = true) -> DockerRequest.Bind? {
        let source = home.appendingPathComponent(relative).path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        guard FileManager.default.isReadableFile(atPath: source) else { return nil }
        return DockerRequest.Bind(source: source, dest: dest, readOnly: readOnly)
    }

    static func readJSONObject(home: URL, relative: String) -> [String: Any]? {
        let url = home.appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
