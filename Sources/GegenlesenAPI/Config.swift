import Foundation
import GegenlesenAgent
import GegenlesenCore
import Vapor

struct ModelSlots: Content, Sendable, Equatable {
    var engineA: String
    var modelA: String
    var engineB: String
    var modelB: String

    enum CodingKeys: String, CodingKey {
        case engineA = "engine_a"
        case modelA = "model_a"
        case engineB = "engine_b"
        case modelB = "model_b"
    }

    init(
        engineA: String = AgentEngineID.opencode,
        modelA: String,
        engineB: String = AgentEngineID.opencode,
        modelB: String
    ) {
        self.engineA = engineA
        self.modelA = modelA
        self.engineB = engineB
        self.modelB = modelB
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engineA = normalizedEngine(try container.decodeIfPresent(String.self, forKey: .engineA))
        modelA = try container.decode(String.self, forKey: .modelA)
        engineB = normalizedEngine(try container.decodeIfPresent(String.self, forKey: .engineB))
        modelB = try container.decode(String.self, forKey: .modelB)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(engineA, forKey: .engineA)
        try container.encode(modelA, forKey: .modelA)
        try container.encode(engineB, forKey: .engineB)
        try container.encode(modelB, forKey: .modelB)
    }
}

struct EngineProfile: Content, Sendable, Equatable, Codable {
    var engine: String
    var model: String

    init(engine: String = AgentEngineID.opencode, model: String) {
        self.engine = engine
        self.model = model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engine = normalizedEngine(try container.decodeIfPresent(String.self, forKey: .engine))
        model = try container.decode(String.self, forKey: .model)
    }

    enum CodingKeys: String, CodingKey {
        case engine, model
    }
}

struct EngineProfiles: Content, Sendable, Equatable, Codable {
    var mine: EngineProfile
    var learn: EngineProfile

    static func `default`(minerModel: String) -> EngineProfiles {
        EngineProfiles(
            mine: EngineProfile(model: minerModel),
            learn: EngineProfile(model: minerModel)
        )
    }
}

struct EmbeddingsConfig: Content, Sendable, Equatable {
    var model: String
    var dimensions: Int
    var maxChunks: Int
    var retrieveK: Int

    enum CodingKeys: String, CodingKey {
        case model, dimensions
        case maxChunks = "max_chunks"
        case retrieveK = "retrieve_k"
    }

    static let v1 = EmbeddingsConfig(
        model: "openai/text-embedding-3-small",
        dimensions: 1536,
        maxChunks: 20_000,
        retrieveK: 12
    )

    init(
        model: String = EmbeddingsConfig.v1.model,
        dimensions: Int = EmbeddingsConfig.v1.dimensions,
        maxChunks: Int = EmbeddingsConfig.v1.maxChunks,
        retrieveK: Int = EmbeddingsConfig.v1.retrieveK
    ) {
        self.model = model
        self.dimensions = dimensions
        self.maxChunks = maxChunks
        self.retrieveK = retrieveK
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.v1.model
        dimensions = try container.decodeIfPresent(Int.self, forKey: .dimensions) ?? Self.v1.dimensions
        maxChunks = try container.decodeIfPresent(Int.self, forKey: .maxChunks) ?? Self.v1.maxChunks
        retrieveK = try container.decodeIfPresent(Int.self, forKey: .retrieveK) ?? Self.v1.retrieveK
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(dimensions, forKey: .dimensions)
        try container.encode(maxChunks, forKey: .maxChunks)
        try container.encode(retrieveK, forKey: .retrieveK)
    }
}

struct Limits: Content, Sendable, Equatable {
    var archiveBytes: Int
    var queuedArchiveBytes: Int
    var agentTimeoutSec: Int
    var judgeTimeoutSec: Int
    var deterministicTimeoutSec: Int
    var identifyTimeoutSec: Int
    var ruleTokenBudget: Int
    /// 0 disables the sweeper. Otherwise learn jobs with new feedback at most this often.
    var learnIntervalMinutes: Int
    var scannerTimeoutSec: Int
    /// Harvest and learn miner containers. Reviewer A/B still use `agentTimeoutSec`.
    var mineTimeoutSec: Int
    /// When true, a single slot validation failure fails the job instead of degrading.
    var reviewStrictMode: Bool

    enum CodingKeys: String, CodingKey {
        case archiveBytes = "archive_bytes"
        case queuedArchiveBytes = "queued_archive_bytes"
        case agentTimeoutSec = "agent_timeout_sec"
        case judgeTimeoutSec = "judge_timeout_sec"
        case deterministicTimeoutSec = "deterministic_timeout_sec"
        case identifyTimeoutSec = "identify_timeout_sec"
        case ruleTokenBudget = "rule_token_budget"
        case learnIntervalMinutes = "learn_interval_minutes"
        case scannerTimeoutSec = "scanner_timeout_sec"
        case mineTimeoutSec = "mine_timeout_sec"
        case reviewStrictMode = "review_strict_mode"
    }

    static let minMineTimeoutSec = 60
    static let maxMineTimeoutSec = 43_200
    static let minAgentTimeoutSec = 60
    static let maxAgentTimeoutSec = 14_400

    static func clampMineTimeout(_ value: Int) -> Int {
        max(minMineTimeoutSec, min(value, maxMineTimeoutSec))
    }

    static func clampAgentTimeout(_ value: Int) -> Int {
        max(minAgentTimeoutSec, min(value, maxAgentTimeoutSec))
    }

    static let v1 = Limits(
        archiveBytes: 104_857_600,
        queuedArchiveBytes: 2_147_483_648,
        agentTimeoutSec: 900,
        judgeTimeoutSec: 300,
        deterministicTimeoutSec: 30,
        identifyTimeoutSec: 60,
        ruleTokenBudget: 6000,
        learnIntervalMinutes: 0,
        scannerTimeoutSec: 120,
        mineTimeoutSec: 3600
    )

    init(
        archiveBytes: Int,
        queuedArchiveBytes: Int,
        agentTimeoutSec: Int,
        judgeTimeoutSec: Int,
        deterministicTimeoutSec: Int,
        identifyTimeoutSec: Int,
        ruleTokenBudget: Int,
        learnIntervalMinutes: Int = 0,
        scannerTimeoutSec: Int = 120,
        mineTimeoutSec: Int = 3600,
        reviewStrictMode: Bool = false
    ) {
        self.archiveBytes = archiveBytes
        self.queuedArchiveBytes = queuedArchiveBytes
        self.agentTimeoutSec = Self.clampAgentTimeout(agentTimeoutSec)
        self.judgeTimeoutSec = judgeTimeoutSec
        self.deterministicTimeoutSec = deterministicTimeoutSec
        self.identifyTimeoutSec = identifyTimeoutSec
        self.ruleTokenBudget = ruleTokenBudget
        self.learnIntervalMinutes = max(0, learnIntervalMinutes)
        self.scannerTimeoutSec = max(1, min(scannerTimeoutSec, 600))
        self.mineTimeoutSec = Self.clampMineTimeout(mineTimeoutSec)
        self.reviewStrictMode = reviewStrictMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            archiveBytes: try container.decode(Int.self, forKey: .archiveBytes),
            queuedArchiveBytes: try container.decode(Int.self, forKey: .queuedArchiveBytes),
            agentTimeoutSec: try container.decode(Int.self, forKey: .agentTimeoutSec),
            judgeTimeoutSec: try container.decode(Int.self, forKey: .judgeTimeoutSec),
            deterministicTimeoutSec: try container.decode(Int.self, forKey: .deterministicTimeoutSec),
            identifyTimeoutSec: try container.decode(Int.self, forKey: .identifyTimeoutSec),
            ruleTokenBudget: try container.decode(Int.self, forKey: .ruleTokenBudget),
            learnIntervalMinutes: try container.decodeIfPresent(Int.self, forKey: .learnIntervalMinutes) ?? 0,
            scannerTimeoutSec: try container.decodeIfPresent(Int.self, forKey: .scannerTimeoutSec) ?? 120,
            mineTimeoutSec: try container.decodeIfPresent(Int.self, forKey: .mineTimeoutSec) ?? 3600,
            reviewStrictMode: try container.decodeIfPresent(Bool.self, forKey: .reviewStrictMode) ?? false
        )
    }
}

struct GegenlesenConfig: Content, Sendable, Equatable {
    var bind: String
    var port: Int
    var dataDir: String
    var models: ModelSlots
    var judgeEngine: String
    var judgeModel: String
    /// Harvest, learn, and architecture-card mining. Independent of the findings judge.
    var minerModel: String
    var opencodeImage: String
    var engineImages: [String: String]
    var engineProfiles: EngineProfiles
    var scannerImage: String
    var embeddings: EmbeddingsConfig
    var limits: Limits
    var risk: RiskConfig
    /// Persisted in config/gegenlesen.json. Never returned by GET /api/settings.
    var openrouterApiKey: String?

    enum CodingKeys: String, CodingKey {
        case bind, port
        case dataDir = "data_dir"
        case models
        case judgeEngine = "judge_engine"
        case judgeModel = "judge_model"
        case minerModel = "miner_model"
        case opencodeImage = "opencode_image"
        case engineImages = "engine_images"
        case engineProfiles = "engine_profiles"
        case scannerImage = "scanner_image"
        case embeddings
        case limits
        case risk
        case openrouterApiKey = "openrouter_api_key"
    }

    init(
        bind: String,
        port: Int,
        dataDir: String,
        models: ModelSlots,
        judgeEngine: String = AgentEngineID.opencode,
        judgeModel: String,
        minerModel: String? = nil,
        opencodeImage: String,
        engineImages: [String: String] = [:],
        engineProfiles: EngineProfiles? = nil,
        scannerImage: String = "gegenlesen/scanner:0.1.0",
        embeddings: EmbeddingsConfig = .v1,
        limits: Limits,
        risk: RiskConfig = .v1,
        openrouterApiKey: String? = nil
    ) {
        self.bind = bind
        self.port = port
        self.dataDir = dataDir
        self.models = models
        self.judgeEngine = judgeEngine
        self.judgeModel = judgeModel
        self.minerModel = Self.resolveMinerModel(minerModel, judgeModel: judgeModel)
        self.opencodeImage = opencodeImage
        self.engineImages = engineImages
        self.engineProfiles = engineProfiles ?? .default(minerModel: self.minerModel)
        self.scannerImage = scannerImage
        self.embeddings = embeddings
        self.limits = limits
        self.risk = risk
        self.openrouterApiKey = openrouterApiKey
    }

    static func resolveMinerModel(_ raw: String?, judgeModel: String) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? judgeModel : trimmed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bind = try container.decode(String.self, forKey: .bind)
        port = try container.decode(Int.self, forKey: .port)
        dataDir = try container.decode(String.self, forKey: .dataDir)
        models = try container.decode(ModelSlots.self, forKey: .models)
        judgeEngine = normalizedEngine(try container.decodeIfPresent(String.self, forKey: .judgeEngine))
        judgeModel = try container.decode(String.self, forKey: .judgeModel)
        minerModel = Self.resolveMinerModel(
            try container.decodeIfPresent(String.self, forKey: .minerModel),
            judgeModel: judgeModel
        )
        opencodeImage = try container.decode(String.self, forKey: .opencodeImage)
        engineImages = try container.decodeIfPresent([String: String].self, forKey: .engineImages) ?? [:]
        engineProfiles = try container.decodeIfPresent(EngineProfiles.self, forKey: .engineProfiles)
            ?? .default(minerModel: minerModel)
        scannerImage = try container.decodeIfPresent(String.self, forKey: .scannerImage) ?? "gegenlesen/scanner:0.1.0"
        embeddings = try container.decodeIfPresent(EmbeddingsConfig.self, forKey: .embeddings) ?? .v1
        limits = try container.decode(Limits.self, forKey: .limits)
        risk = try container.decodeIfPresent(RiskConfig.self, forKey: .risk) ?? .v1
        openrouterApiKey = try container.decodeIfPresent(String.self, forKey: .openrouterApiKey)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bind, forKey: .bind)
        try container.encode(port, forKey: .port)
        try container.encode(dataDir, forKey: .dataDir)
        try container.encode(models, forKey: .models)
        try container.encode(judgeEngine, forKey: .judgeEngine)
        try container.encode(judgeModel, forKey: .judgeModel)
        try container.encode(minerModel, forKey: .minerModel)
        try container.encode(opencodeImage, forKey: .opencodeImage)
        if !engineImages.isEmpty {
            try container.encode(engineImages, forKey: .engineImages)
        }
        try container.encode(engineProfiles, forKey: .engineProfiles)
        try container.encode(scannerImage, forKey: .scannerImage)
        try container.encode(embeddings, forKey: .embeddings)
        try container.encode(limits, forKey: .limits)
        try container.encode(risk, forKey: .risk)
        if let openrouterApiKey, !openrouterApiKey.isEmpty {
            try container.encode(openrouterApiKey, forKey: .openrouterApiKey)
        }
    }

    static let example = GegenlesenConfig(
        bind: "127.0.0.1",
        port: 8080,
        dataDir: "var",
        models: ModelSlots(
            modelA: "openrouter/deepseek/deepseek-v4-flash",
            modelB: "openrouter/google/gemini-3.7-flash"
        ),
        judgeModel: "openrouter/openai/gpt-5.6-terra",
        minerModel: "openrouter/openai/gpt-5.6-terra",
        opencodeImage: "gegenlesen/opencode-runner:0.1.0",
        engineImages: [
            AgentEngineID.opencode: "gegenlesen/opencode-runner:0.1.0",
            AgentEngineID.claude: "gegenlesen/claude-runner:0.1.0",
            AgentEngineID.codex: "gegenlesen/codex-runner:0.1.0",
            AgentEngineID.cursorAgent: "gegenlesen/cursor-runner:0.1.0",
            AgentEngineID.grok: "gegenlesen/grok-runner:0.1.0",
        ],
        scannerImage: "gegenlesen/scanner:0.1.0",
        limits: .v1
    )

    struct Loaded: Sendable {
        var config: GegenlesenConfig
        /// Writable path. Example JSON is only a template.
        var fileURL: URL
    }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> GegenlesenConfig {
        try loadDetailed(environment: environment, fileManager: fileManager, cwd: cwd).config
    }

    static func loadDetailed(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> Loaded {
        let writable = cwd.appendingPathComponent("config/gegenlesen.json")
        let candidates: [(url: URL, writable: URL)] = {
            if let override = environment["GEGENLESEN_CONFIG"], !override.isEmpty {
                let url = URL(fileURLWithPath: override)
                return [(url, url)]
            }
            return [
                (writable, writable),
                (cwd.appendingPathComponent("config/gegenlesen.example.json"), writable),
            ]
        }()

        var config = example
        var fileURL = writable
        for candidate in candidates {
            guard fileManager.fileExists(atPath: candidate.url.path) else { continue }
            let data = try Data(contentsOf: candidate.url)
            config = try JSONDecoder().decode(GegenlesenConfig.self, from: data)
            fileURL = candidate.writable
            break
        }
        config = config.applyingEnvironmentOverrides(environment)
        config.installOpenRouterKeyInProcess(environment: environment)
        return Loaded(config: config, fileURL: fileURL)
    }

    func persist(to url: URL, fileManager: FileManager = .default) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func installOpenRouterKeyInProcess(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let existing = environment["OPENROUTER_API_KEY"] ?? ""
        if !existing.isEmpty { return }
        guard let key = openrouterApiKey, !key.isEmpty else { return }
        setenv("OPENROUTER_API_KEY", key, 1)
    }

    func providerEnv(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String] = [:]
        for key in [
            "ANTHROPIC_API_KEY",
            "OPENAI_API_KEY",
            "OPENROUTER_API_KEY",
            "CODEX_API_KEY",
            "CURSOR_API_KEY",
            "CURSOR_AUTH_TOKEN",
            "XAI_API_KEY",
            "GROK_API_KEY",
        ] {
            if let value = environment[key], !value.isEmpty {
                env[key] = value
            }
        }
        if env["OPENROUTER_API_KEY"] == nil, let key = openrouterApiKey, !key.isEmpty {
            env["OPENROUTER_API_KEY"] = key
        }
        return env
    }

    func isOpenRouterConfigured(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let key = openrouterApiKey, !key.isEmpty { return true }
        if let key = environment["OPENROUTER_API_KEY"], !key.isEmpty { return true }
        return false
    }

    static let defaultClaudeRunnerImage = "gegenlesen/claude-runner:0.1.0"
    static let defaultCodexRunnerImage = "gegenlesen/codex-runner:0.1.0"
    static let defaultCursorRunnerImage = "gegenlesen/cursor-runner:0.1.0"
    static let defaultGrokRunnerImage = "gegenlesen/grok-runner:0.1.0"

    func resolvedEngineImages() -> [String: String] {
        var map: [String: String] = [
            AgentEngineID.opencode: opencodeImage,
            AgentEngineID.claude: Self.defaultClaudeRunnerImage,
            AgentEngineID.codex: Self.defaultCodexRunnerImage,
            AgentEngineID.cursorAgent: Self.defaultCursorRunnerImage,
            AgentEngineID.grok: Self.defaultGrokRunnerImage,
        ]
        for (engine, image) in engineImages {
            let trimmed = image.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            map[engine] = trimmed
        }
        map[AgentEngineID.opencode] = opencodeImage
        return map
    }

    func runnerImage(for engine: String) -> String {
        let normalized = engine.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == AgentEngineID.opencode {
            return opencodeImage
        }
        return resolvedEngineImages()[normalized] ?? opencodeImage
    }

    func applyingEnvironmentOverrides(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GegenlesenConfig {
        var next = self
        if let value = environment["GEGENLESEN_BIND"], !value.isEmpty {
            next.bind = value
        }
        if let value = environment["GEGENLESEN_PORT"], let port = Int(value) {
            next.port = port
        }
        if let value = environment["GEGENLESEN_DATA_DIR"], !value.isEmpty {
            next.dataDir = value
        }
        if let value = environment["GEGENLESEN_MODEL_A"], !value.isEmpty {
            next.models.modelA = value
        }
        if let value = environment["GEGENLESEN_MODEL_B"], !value.isEmpty {
            next.models.modelB = value
        }
        if let value = environment["GEGENLESEN_ENGINE_A"], !value.isEmpty {
            next.models.engineA = value
        }
        if let value = environment["GEGENLESEN_ENGINE_B"], !value.isEmpty {
            next.models.engineB = value
        }
        if let value = environment["GEGENLESEN_JUDGE_MODEL"], !value.isEmpty {
            next.judgeModel = value
        }
        if let value = environment["GEGENLESEN_JUDGE_ENGINE"], !value.isEmpty {
            next.judgeEngine = value
        }
        if let value = environment["GEGENLESEN_MINER_MODEL"], !value.isEmpty {
            next.minerModel = value
        }
        if let value = environment["GEGENLESEN_OPENCODE_IMAGE"], !value.isEmpty {
            next.opencodeImage = value
        }
        if let value = environment["GEGENLESEN_CLAUDE_RUNNER_IMAGE"], !value.isEmpty {
            next.engineImages[AgentEngineID.claude] = value
        }
        if let value = environment["GEGENLESEN_CODEX_RUNNER_IMAGE"], !value.isEmpty {
            next.engineImages[AgentEngineID.codex] = value
        }
        if let value = environment["GEGENLESEN_CURSOR_RUNNER_IMAGE"], !value.isEmpty {
            next.engineImages[AgentEngineID.cursorAgent] = value
        }
        if let value = environment["GEGENLESEN_GROK_RUNNER_IMAGE"], !value.isEmpty {
            next.engineImages[AgentEngineID.grok] = value
        }
        if let value = environment["GEGENLESEN_MINE_ENGINE"], !value.isEmpty {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if AgentEngineID.isKnown(trimmed) {
                next.engineProfiles.mine.engine = trimmed
            }
        }
        if let value = environment["GEGENLESEN_MINE_MODEL"], !value.isEmpty {
            next.engineProfiles.mine.model = value
        }
        if let value = environment["GEGENLESEN_LEARN_ENGINE"], !value.isEmpty {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if AgentEngineID.isKnown(trimmed) {
                next.engineProfiles.learn.engine = trimmed
            }
        }
        if let value = environment["GEGENLESEN_LEARN_MODEL"], !value.isEmpty {
            next.engineProfiles.learn.model = value
        }
        if let value = environment["GEGENLESEN_REVIEW_STRICT_MODE"], !value.isEmpty {
            next.limits.reviewStrictMode = ["1", "true", "yes"].contains(value.lowercased())
        }
        if let value = environment["GEGENLESEN_SCANNER_IMAGE"] {
            next.scannerImage = value
        }
        if let value = environment["GEGENLESEN_EMBEDDING_MODEL"], !value.isEmpty {
            next.embeddings.model = value
        }
        if let value = environment["GEGENLESEN_RULE_TOKEN_BUDGET"], let budget = Int(value) {
            next.limits.ruleTokenBudget = budget
        }
        if let value = environment["GEGENLESEN_LEARN_INTERVAL_MINUTES"], let minutes = Int(value) {
            next.limits.learnIntervalMinutes = max(0, minutes)
        }
        if let value = environment["GEGENLESEN_MINE_TIMEOUT_SEC"], let seconds = Int(value) {
            next.limits.mineTimeoutSec = Limits.clampMineTimeout(seconds)
        }
        if let value = environment["GEGENLESEN_AGENT_TIMEOUT_SEC"], let seconds = Int(value) {
            next.limits.agentTimeoutSec = Limits.clampAgentTimeout(seconds)
        }
        if let value = environment["GEGENLESEN_RISK_MODE"], let mode = RiskMode(rawValue: value) {
            next.risk.mode = mode
        }
        if let value = environment["GEGENLESEN_RISK_APPETITE"], let appetite = Int(value) {
            next.risk.appetite = min(max(appetite, 1), 5)
        }
        return next
    }

    var settingsDTO: SettingsDTO {
        settingsDTO(environment: ProcessInfo.processInfo.environment)
    }

    func engineAuthStatus(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: EngineAuthStatus] {
        var statuses = EngineHostCredentials.probeAll(
            homeDirectory: EngineHostCredentials.hostHomeDirectory(environment: environment),
            environment: providerEnv(from: environment)
        )
        if isOpenRouterConfigured(environment: environment) {
            statuses[AgentEngineID.opencode] = EngineAuthStatus(apiKey: true, cliLogin: false)
        }
        return statuses
    }

    func settingsDTO(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SettingsDTO {
        SettingsDTO(
            bind: bind,
            port: port,
            models: models,
            judgeEngine: judgeEngine,
            judgeModel: judgeModel,
            minerModel: minerModel,
            engineProfiles: engineProfiles,
            opencodeImage: opencodeImage,
            scannerImage: scannerImage,
            limits: limits,
            openrouterConfigured: isOpenRouterConfigured(environment: environment),
            engineAuth: engineAuthStatus(environment: environment),
            risk: risk
        )
    }
}

struct HealthDTO: Content, Sendable, Equatable {
    var ok: Bool
    var version: String
}

struct SettingsDTO: Content, Sendable, Equatable {
    var bind: String
    var port: Int
    var models: ModelSlots
    var judgeEngine: String
    var judgeModel: String
    var minerModel: String
    var engineProfiles: EngineProfiles
    var opencodeImage: String
    var scannerImage: String
    var limits: Limits
    var openrouterConfigured: Bool
    var engineAuth: [String: EngineAuthStatus]
    var risk: RiskConfig

    enum CodingKeys: String, CodingKey {
        case bind, port, models
        case judgeEngine = "judge_engine"
        case judgeModel = "judge_model"
        case minerModel = "miner_model"
        case engineProfiles = "engine_profiles"
        case opencodeImage = "opencode_image"
        case scannerImage = "scanner_image"
        case limits
        case openrouterConfigured = "openrouter_configured"
        case engineAuth = "engine_auth"
        case risk
    }
}

struct RiskSettingsUpdate: Content, Sendable, Equatable {
    var mode: RiskMode?
    var appetite: Int?

    enum CodingKeys: String, CodingKey {
        case mode, appetite
    }
}

struct LimitsSettingsUpdate: Content, Sendable, Equatable {
    var mineTimeoutSec: Int?
    var agentTimeoutSec: Int?
    var learnIntervalMinutes: Int?
    var reviewStrictMode: Bool?

    enum CodingKeys: String, CodingKey {
        case mineTimeoutSec = "mine_timeout_sec"
        case agentTimeoutSec = "agent_timeout_sec"
        case learnIntervalMinutes = "learn_interval_minutes"
        case reviewStrictMode = "review_strict_mode"
    }
}

struct EngineProfileUpdate: Content, Sendable, Equatable {
    var engine: String?
    var model: String?
}

struct EngineProfilesUpdate: Content, Sendable, Equatable {
    var mine: EngineProfileUpdate?
    var learn: EngineProfileUpdate?

    enum CodingKeys: String, CodingKey {
        case mine, learn
    }
}

struct ModelSlotsUpdate: Content, Sendable, Equatable {
    var engineA: String? = nil
    var modelA: String? = nil
    var engineB: String? = nil
    var modelB: String? = nil

    enum CodingKeys: String, CodingKey {
        case engineA = "engine_a"
        case modelA = "model_a"
        case engineB = "engine_b"
        case modelB = "model_b"
    }
}

struct SettingsUpdate: Content, Sendable, Equatable {
    var models: ModelSlotsUpdate?
    var judgeEngine: String? = nil
    var judgeModel: String?
    var minerModel: String? = nil
    var engineProfiles: EngineProfilesUpdate? = nil
    var openrouterApiKey: String?
    var scannerImage: String? = nil
    var risk: RiskSettingsUpdate? = nil
    var limits: LimitsSettingsUpdate? = nil

    enum CodingKeys: String, CodingKey {
        case models
        case judgeEngine = "judge_engine"
        case judgeModel = "judge_model"
        case minerModel = "miner_model"
        case engineProfiles = "engine_profiles"
        case openrouterApiKey = "openrouter_api_key"
        case scannerImage = "scanner_image"
        case risk
        case limits
    }
}

private struct GegenlesenConfigKey: StorageKey {
    typealias Value = GegenlesenConfig
}

private func normalizedEngine(_ raw: String?) -> String {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? AgentEngineID.opencode : trimmed
}

private struct GegenlesenConfigFileKey: StorageKey {
    typealias Value = URL
}

extension Application {
    var gegenlesenConfig: GegenlesenConfig {
        get {
            guard let value = storage[GegenlesenConfigKey.self] else {
                fatalError("GegenlesenConfig missing; call configure(_:config:) first")
            }
            return value
        }
        set { storage[GegenlesenConfigKey.self] = newValue }
    }

    var gegenlesenConfigFileURL: URL? {
        get { storage[GegenlesenConfigFileKey.self] }
        set { storage[GegenlesenConfigFileKey.self] = newValue }
    }
}
