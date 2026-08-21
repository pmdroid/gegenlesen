import Foundation
import Vapor

struct ModelSlots: Content, Sendable, Equatable {
    var modelA: String
    var modelB: String

    enum CodingKeys: String, CodingKey {
        case modelA = "model_a"
        case modelB = "model_b"
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
    }

    static let v1 = Limits(
        archiveBytes: 104_857_600,
        queuedArchiveBytes: 2_147_483_648,
        agentTimeoutSec: 900,
        judgeTimeoutSec: 300,
        deterministicTimeoutSec: 30,
        identifyTimeoutSec: 60,
        ruleTokenBudget: 6000,
        learnIntervalMinutes: 15,
        scannerTimeoutSec: 120
    )

    init(
        archiveBytes: Int,
        queuedArchiveBytes: Int,
        agentTimeoutSec: Int,
        judgeTimeoutSec: Int,
        deterministicTimeoutSec: Int,
        identifyTimeoutSec: Int,
        ruleTokenBudget: Int,
        learnIntervalMinutes: Int = 15,
        scannerTimeoutSec: Int = 120
    ) {
        self.archiveBytes = archiveBytes
        self.queuedArchiveBytes = queuedArchiveBytes
        self.agentTimeoutSec = agentTimeoutSec
        self.judgeTimeoutSec = judgeTimeoutSec
        self.deterministicTimeoutSec = deterministicTimeoutSec
        self.identifyTimeoutSec = identifyTimeoutSec
        self.ruleTokenBudget = ruleTokenBudget
        self.learnIntervalMinutes = max(0, learnIntervalMinutes)
        self.scannerTimeoutSec = max(1, min(scannerTimeoutSec, 600))
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
            learnIntervalMinutes: try container.decodeIfPresent(Int.self, forKey: .learnIntervalMinutes) ?? 15,
            scannerTimeoutSec: try container.decodeIfPresent(Int.self, forKey: .scannerTimeoutSec) ?? 120
        )
    }
}

struct GegenlesenConfig: Content, Sendable, Equatable {
    var bind: String
    var port: Int
    var dataDir: String
    var models: ModelSlots
    var judgeModel: String
    var opencodeImage: String
    var scannerImage: String
    var embeddings: EmbeddingsConfig
    var limits: Limits
    /// Persisted in config/gegenlesen.json. Never returned by GET /api/settings.
    var openrouterApiKey: String?

    enum CodingKeys: String, CodingKey {
        case bind, port
        case dataDir = "data_dir"
        case models
        case judgeModel = "judge_model"
        case opencodeImage = "opencode_image"
        case scannerImage = "scanner_image"
        case embeddings
        case limits
        case openrouterApiKey = "openrouter_api_key"
    }

    init(
        bind: String,
        port: Int,
        dataDir: String,
        models: ModelSlots,
        judgeModel: String,
        opencodeImage: String,
        scannerImage: String = "gegenlesen/scanner:0.1.0",
        embeddings: EmbeddingsConfig = .v1,
        limits: Limits,
        openrouterApiKey: String? = nil
    ) {
        self.bind = bind
        self.port = port
        self.dataDir = dataDir
        self.models = models
        self.judgeModel = judgeModel
        self.opencodeImage = opencodeImage
        self.scannerImage = scannerImage
        self.embeddings = embeddings
        self.limits = limits
        self.openrouterApiKey = openrouterApiKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bind = try container.decode(String.self, forKey: .bind)
        port = try container.decode(Int.self, forKey: .port)
        dataDir = try container.decode(String.self, forKey: .dataDir)
        models = try container.decode(ModelSlots.self, forKey: .models)
        judgeModel = try container.decode(String.self, forKey: .judgeModel)
        opencodeImage = try container.decode(String.self, forKey: .opencodeImage)
        scannerImage = try container.decodeIfPresent(String.self, forKey: .scannerImage) ?? "gegenlesen/scanner:0.1.0"
        embeddings = try container.decodeIfPresent(EmbeddingsConfig.self, forKey: .embeddings) ?? .v1
        limits = try container.decode(Limits.self, forKey: .limits)
        openrouterApiKey = try container.decodeIfPresent(String.self, forKey: .openrouterApiKey)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bind, forKey: .bind)
        try container.encode(port, forKey: .port)
        try container.encode(dataDir, forKey: .dataDir)
        try container.encode(models, forKey: .models)
        try container.encode(judgeModel, forKey: .judgeModel)
        try container.encode(opencodeImage, forKey: .opencodeImage)
        try container.encode(scannerImage, forKey: .scannerImage)
        try container.encode(embeddings, forKey: .embeddings)
        try container.encode(limits, forKey: .limits)
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
        opencodeImage: "gegenlesen/opencode-runner:0.1.0",
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
        for key in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY"] {
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
        if let value = environment["GEGENLESEN_JUDGE_MODEL"], !value.isEmpty {
            next.judgeModel = value
        }
        if let value = environment["GEGENLESEN_OPENCODE_IMAGE"], !value.isEmpty {
            next.opencodeImage = value
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
        return next
    }

    var settingsDTO: SettingsDTO {
        settingsDTO(environment: ProcessInfo.processInfo.environment)
    }

    func settingsDTO(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SettingsDTO {
        SettingsDTO(
            bind: bind,
            port: port,
            models: models,
            judgeModel: judgeModel,
            opencodeImage: opencodeImage,
            scannerImage: scannerImage,
            limits: limits,
            openrouterConfigured: isOpenRouterConfigured(environment: environment)
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
    var judgeModel: String
    var opencodeImage: String
    var scannerImage: String
    var limits: Limits
    var openrouterConfigured: Bool

    enum CodingKeys: String, CodingKey {
        case bind, port, models
        case judgeModel = "judge_model"
        case opencodeImage = "opencode_image"
        case scannerImage = "scanner_image"
        case limits
        case openrouterConfigured = "openrouter_configured"
    }
}

struct SettingsUpdate: Content, Sendable, Equatable {
    var models: ModelSlots?
    var judgeModel: String?
    var openrouterApiKey: String?

    enum CodingKeys: String, CodingKey {
        case models
        case judgeModel = "judge_model"
        case openrouterApiKey = "openrouter_api_key"
    }
}

private struct GegenlesenConfigKey: StorageKey {
    typealias Value = GegenlesenConfig
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
