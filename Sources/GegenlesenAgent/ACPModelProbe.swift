import Foundation
import GegenlesenCore

public struct EngineModelDTO: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public struct EngineModelList: Sendable, Equatable, Codable {
    public var engine: String
    public var models: [EngineModelDTO]
    public var source: String

    public init(engine: String, models: [EngineModelDTO], source: String) {
        self.engine = engine
        self.models = models
        self.source = source
    }
}

public enum ACPModelProbeError: Error, Sendable, Equatable {
    case unsupportedEngine(String)
    case scriptMissing
    case probeFailed(String)
    case engineNotConfigured(String)
}

public enum ACPModelProbe {
    private static let cacheTTL: Duration = .seconds(300)
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: (expires: ContinuousClock.Instant, list: EngineModelList)] = [:]

    public static func listModels(
        engine: String,
        packageRoot: String?,
        providerEnv: [String: String] = [:],
        skipCache: Bool = false
    ) async throws -> EngineModelList {
        let normalized = engine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ACPEngines.usesACP(normalized) else {
            throw ACPModelProbeError.unsupportedEngine(normalized)
        }
        let auth = EngineHostCredentials.probeEngine(
            engine: normalized,
            home: EngineHostCredentials.hostHomeDirectory(),
            providerEnv: providerEnv
        )
        guard auth.configured else {
            throw ACPModelProbeError.engineNotConfigured(normalized)
        }
        if !skipCache, let cached = cachedList(for: normalized) {
            return cached
        }

        let enrichedEnv = EngineHostCredentials.enrichedProviderEnv(
            engine: normalized,
            homeDirectory: EngineHostCredentials.hostHomeDirectory(),
            providerEnv: providerEnv
        )
        let list = try await Task.detached {
            let command = try probeCommand(for: normalized)
            return try runProbe(
                engine: normalized,
                script: scriptURL(packageRoot: packageRoot),
                command: command,
                providerEnv: enrichedEnv
            )
        }.value
        storeCache(list, engine: normalized)
        return list
    }

    private static func runProbe(
        engine: String,
        script: URL,
        command: [String],
        providerEnv: [String: String]
    ) throws -> EngineModelList {
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            throw ACPModelProbeError.scriptMissing
        }

        let (env, cwd) = try probeRuntimeEnvironment(engine: engine, providerEnv: providerEnv)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path, "--"] + command
        process.environment = env
        process.currentDirectoryURL = cwd

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let outBox = DataBox()
        let errBox = DataBox()
        let outReader = Thread {
            outBox.value = stdout.fileHandleForReading.readDataToEndOfFile()
        }
        let errReader = Thread {
            errBox.value = stderr.fileHandleForReading.readDataToEndOfFile()
        }
        outReader.start()
        errReader.start()

        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                throw ACPModelProbeError.probeFailed("ACP model probe timed out")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        while outReader.isExecuting || errReader.isExecuting {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let outData = outBox.value
        let errData = errBox.value

        guard process.terminationStatus == 0 else {
            let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ACPModelProbeError.probeFailed(err?.isEmpty == false ? err! : "exit \(process.terminationStatus)")
        }

        let decoded = try JSONDecoder().decode(ProbePayload.self, from: outData)
        return EngineModelList(
            engine: engine,
            models: decoded.models.map {
                EngineModelDTO(id: $0.id, name: $0.name, description: $0.description)
            },
            source: decoded.source
        )
    }

    private struct ProbePayload: Decodable {
        var models: [EngineModelDTO]
        var source: String
    }

    private final class DataBox: @unchecked Sendable {
        var value = Data()
    }

    private static func probeRuntimeEnvironment(
        engine: String,
        providerEnv: [String: String]
    ) throws -> (env: [String: String], cwd: URL) {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in providerEnv where !value.isEmpty {
            env[key] = value
        }

        let hostHomeRaw = env["GEGENLESEN_HOST_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !hostHomeRaw.isEmpty else {
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            return (env, home)
        }

        let hostHome = URL(fileURLWithPath: hostHomeRaw, isDirectory: true)
        if engine == AgentEngineID.codex {
            let probeHome = FileManager.default.temporaryDirectory
                .appendingPathComponent("gegenlesen-acp-probe-codex", isDirectory: true)
            let codexDir = probeHome.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
            let authSource = hostHome.appendingPathComponent(".codex/auth.json")
            let authDest = codexDir.appendingPathComponent("auth.json")
            if FileManager.default.isReadableFile(atPath: authSource.path) {
                if FileManager.default.fileExists(atPath: authDest.path) {
                    try FileManager.default.removeItem(at: authDest)
                }
                try FileManager.default.copyItem(at: authSource, to: authDest)
            }
            env["HOME"] = probeHome.path
            return (env, probeHome)
        }

        env["HOME"] = hostHomeRaw
        return (env, hostHome)
    }

    private static func probeCommand(for engine: String) throws -> [String] {
        let home = EngineHostCredentials.hostHomeDirectory()
        switch engine {
        case AgentEngineID.claude:
            if FileManager.default.isExecutableFile(atPath: "/usr/bin/claude-code-acp")
                || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/claude-code-acp") {
                return ["claude-code-acp"]
            }
            return ["npx", "-y", "@zed-industries/claude-code-acp@0.16.2"]
        case AgentEngineID.codex:
            return ["npx", "-y", "@agentclientprotocol/codex-acp"]
        case AgentEngineID.cursorAgent:
            if let agent = EngineAgentPaths.cursorAgent(home: home) {
                return [agent, "acp"]
            }
            throw ACPModelProbeError.probeFailed("cursor agent binary not found — rebuild API image or set GEGENLESEN_CURSOR_AGENT")
        case AgentEngineID.grok:
            if let agent = EngineAgentPaths.grokAgent(home: home) {
                return [agent, "agent", "stdio"]
            }
            throw ACPModelProbeError.probeFailed("grok agent binary not found — rebuild API image or set GEGENLESEN_GROK_AGENT")
        default:
            return []
        }
    }

    private static func scriptURL(packageRoot: String?) -> URL {
        if let root = packageRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("docker/runner-base/acp-models.mjs")
        }
        if let root = ProcessInfo.processInfo.environment["GEGENLESEN_ROOT"] {
            return URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("docker/runner-base/acp-models.mjs")
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("docker/runner-base/acp-models.mjs")
    }

    private static func cachedList(for engine: String) -> EngineModelList? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = cache[engine], ContinuousClock.now < entry.expires else {
            cache.removeValue(forKey: engine)
            return nil
        }
        return entry.list
    }

    private static func storeCache(_ list: EngineModelList, engine: String) {
        cacheLock.lock()
        cache[engine] = (expires: ContinuousClock.now + cacheTTL, list: list)
        cacheLock.unlock()
    }
}
