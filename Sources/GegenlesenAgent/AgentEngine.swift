import Foundation
import GegenlesenCore

public typealias AgentInvoking = ReviewerRunning & MinerRunning & JudgeRunning & SuggestionJudging

public enum AgentEngineError: Error, Sendable, Equatable {
    case unknownEngine(String)
}

public struct AgentEngineConfiguration: Sendable {
    public var docker: any DockerExecuting
    public var image: String
    public var engineImages: [String: String]
    public var runnerConfig: URL
    public var cpus: String
    public var memory: String
    public var agentTimeout: Duration
    public var judgeTimeout: Duration
    public var providerEnv: [String: String]
    public var schemasDirectory: URL?
    public var transcriptWriter: (@Sendable (JobID, String, Data) -> Void)?
    public var prepareRunnerConfig: (@Sendable (JobID, String?) async throws -> Void)?

    public init(
        docker: any DockerExecuting,
        image: String,
        engineImages: [String: String] = [:],
        runnerConfig: URL,
        cpus: String = ProcessInfo.processInfo.environment["GEGENLESEN_DOCKER_CPUS"] ?? "2",
        memory: String = ProcessInfo.processInfo.environment["GEGENLESEN_DOCKER_MEMORY"] ?? "4g",
        agentTimeout: Duration = .seconds(900),
        judgeTimeout: Duration = .seconds(300),
        providerEnv: [String: String] = [:],
        schemasDirectory: URL? = nil,
        transcriptWriter: (@Sendable (JobID, String, Data) -> Void)? = nil,
        prepareRunnerConfig: (@Sendable (JobID, String?) async throws -> Void)? = nil
    ) {
        self.docker = docker
        self.image = image
        self.engineImages = engineImages
        self.runnerConfig = runnerConfig
        self.cpus = cpus
        self.memory = memory
        self.agentTimeout = agentTimeout
        self.judgeTimeout = judgeTimeout
        self.providerEnv = providerEnv
        self.schemasDirectory = schemasDirectory
        self.transcriptWriter = transcriptWriter
        self.prepareRunnerConfig = prepareRunnerConfig
    }
}

public protocol AgentEngine: Sendable {
    var id: String { get }
    func makeInvocation(_ configuration: AgentEngineConfiguration) -> any AgentInvoking
}

public struct OpenCodeEngine: AgentEngine {
    public static let engineID = "opencode"

    public let id = OpenCodeEngine.engineID

    public init() {}

    public func makeInvocation(_ configuration: AgentEngineConfiguration) -> any AgentInvoking {
        OpenCodeInvocation(
            docker: configuration.docker,
            image: configuration.image,
            engineImages: configuration.engineImages,
            runnerConfig: configuration.runnerConfig,
            cpus: configuration.cpus,
            memory: configuration.memory,
            agentTimeout: configuration.agentTimeout,
            judgeTimeout: configuration.judgeTimeout,
            providerEnv: configuration.providerEnv,
            schemasDirectory: configuration.schemasDirectory,
            transcriptWriter: configuration.transcriptWriter,
            prepareRunnerConfig: configuration.prepareRunnerConfig
        )
    }
}

public struct ClaudeEngine: AgentEngine {
    public static let engineID = AgentEngineID.claude

    public let id = ClaudeEngine.engineID

    public init() {}

    public func makeInvocation(_ configuration: AgentEngineConfiguration) -> any AgentInvoking {
        OpenCodeInvocation(
            docker: configuration.docker,
            image: configuration.image,
            engineImages: configuration.engineImages,
            runnerConfig: configuration.runnerConfig,
            cpus: configuration.cpus,
            memory: configuration.memory,
            agentTimeout: configuration.agentTimeout,
            judgeTimeout: configuration.judgeTimeout,
            providerEnv: configuration.providerEnv,
            schemasDirectory: configuration.schemasDirectory,
            transcriptWriter: configuration.transcriptWriter,
            prepareRunnerConfig: configuration.prepareRunnerConfig
        )
    }
}

public struct AgentEngineRegistry: Sendable {
    public static let defaultEngineID = OpenCodeEngine.engineID
    public static let `default` = AgentEngineRegistry(engines: [OpenCodeEngine(), ClaudeEngine()])

    private let engines: [String: any AgentEngine]

    public init(engines: [any AgentEngine]) {
        var map: [String: any AgentEngine] = [:]
        for engine in engines {
            map[engine.id] = engine
        }
        self.engines = map
    }

    public var engineIDs: [String] {
        engines.keys.sorted()
    }

    public func engine(id: String) throws -> any AgentEngine {
        guard let engine = engines[id] else {
            throw AgentEngineError.unknownEngine(id)
        }
        return engine
    }
}
