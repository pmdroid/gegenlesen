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

        let list = try await Task.detached {
            try runProbe(
                engine: normalized,
                script: scriptURL(packageRoot: packageRoot),
                command: probeCommand(for: normalized),
                providerEnv: providerEnv
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

        var env = ProcessInfo.processInfo.environment
        for (key, value) in providerEnv where !value.isEmpty {
            env[key] = value
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path, "--"] + command
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

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
        let deadline = Date().addingTimeInterval(90)
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

    private static func probeCommand(for engine: String) -> [String] {
        let home = EngineHostCredentials.hostHomeDirectory()
        switch engine {
        case AgentEngineID.claude:
            return ["npx", "-y", "@zed-industries/claude-code-acp@0.16.2"]
        case AgentEngineID.codex:
            return ["npx", "-y", "@agentclientprotocol/codex-acp"]
        case AgentEngineID.cursorAgent:
            if let agent = EngineAgentPaths.cursorAgent(home: home) {
                return [agent, "acp"]
            }
            return ["agent", "acp"]
        case AgentEngineID.grok:
            if let agent = EngineAgentPaths.grokAgent(home: home) {
                return [agent, "agent", "stdio"]
            }
            return ["agent", "agent", "stdio"]
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
