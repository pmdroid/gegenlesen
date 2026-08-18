import Foundation
import Vapor

enum MeisterVersion {
    static let current = "0.1.0"
}

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

    enum CodingKeys: String, CodingKey {
        case archiveBytes = "archive_bytes"
        case queuedArchiveBytes = "queued_archive_bytes"
        case agentTimeoutSec = "agent_timeout_sec"
        case judgeTimeoutSec = "judge_timeout_sec"
        case deterministicTimeoutSec = "deterministic_timeout_sec"
        case identifyTimeoutSec = "identify_timeout_sec"
        case ruleTokenBudget = "rule_token_budget"
    }

    static let v1 = Limits(
        archiveBytes: 104_857_600,
        queuedArchiveBytes: 2_147_483_648,
        agentTimeoutSec: 900,
        judgeTimeoutSec: 300,
        deterministicTimeoutSec: 30,
        identifyTimeoutSec: 60,
        ruleTokenBudget: 6000
    )
}

struct MeisterConfig: Content, Sendable, Equatable {
    var bind: String
    var port: Int
    var dataDir: String
    var models: ModelSlots
    var judgeModel: String
    var opencodeImage: String
    var embeddings: EmbeddingsConfig
    var limits: Limits

    enum CodingKeys: String, CodingKey {
        case bind, port
        case dataDir = "data_dir"
        case models
        case judgeModel = "judge_model"
        case opencodeImage = "opencode_image"
        case embeddings
        case limits
    }

    init(
        bind: String,
        port: Int,
        dataDir: String,
        models: ModelSlots,
        judgeModel: String,
        opencodeImage: String,
        embeddings: EmbeddingsConfig = .v1,
        limits: Limits
    ) {
        self.bind = bind
        self.port = port
        self.dataDir = dataDir
        self.models = models
        self.judgeModel = judgeModel
        self.opencodeImage = opencodeImage
        self.embeddings = embeddings
        self.limits = limits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bind = try container.decode(String.self, forKey: .bind)
        port = try container.decode(Int.self, forKey: .port)
        dataDir = try container.decode(String.self, forKey: .dataDir)
        models = try container.decode(ModelSlots.self, forKey: .models)
        judgeModel = try container.decode(String.self, forKey: .judgeModel)
        opencodeImage = try container.decode(String.self, forKey: .opencodeImage)
        embeddings = try container.decodeIfPresent(EmbeddingsConfig.self, forKey: .embeddings) ?? .v1
        limits = try container.decode(Limits.self, forKey: .limits)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bind, forKey: .bind)
        try container.encode(port, forKey: .port)
        try container.encode(dataDir, forKey: .dataDir)
        try container.encode(models, forKey: .models)
        try container.encode(judgeModel, forKey: .judgeModel)
        try container.encode(opencodeImage, forKey: .opencodeImage)
        try container.encode(embeddings, forKey: .embeddings)
        try container.encode(limits, forKey: .limits)
    }

    static let example = MeisterConfig(
        bind: "127.0.0.1",
        port: 8080,
        dataDir: "var",
        models: ModelSlots(
            modelA: "anthropic/claude-sonnet-4-5",
            modelB: "openai/gpt-5.2"
        ),
        judgeModel: "anthropic/claude-sonnet-4-5",
        opencodeImage: "meister/opencode-runner:0.1.0",
        limits: .v1
    )

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> MeisterConfig {
        let candidates: [URL] = {
            if let override = environment["MEISTER_CONFIG"], !override.isEmpty {
                return [URL(fileURLWithPath: override)]
            }
            return [
                cwd.appendingPathComponent("config/meister.json"),
                cwd.appendingPathComponent("config/meister.example.json"),
            ]
        }()

        var config = example
        for url in candidates {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            config = try JSONDecoder().decode(MeisterConfig.self, from: data)
            break
        }
        return config.applyingEnvironmentOverrides(environment)
    }

    func applyingEnvironmentOverrides(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MeisterConfig {
        var next = self
        if let value = environment["MEISTER_BIND"], !value.isEmpty {
            next.bind = value
        }
        if let value = environment["MEISTER_PORT"], let port = Int(value) {
            next.port = port
        }
        if let value = environment["MEISTER_DATA_DIR"], !value.isEmpty {
            next.dataDir = value
        }
        if let value = environment["MEISTER_MODEL_A"], !value.isEmpty {
            next.models.modelA = value
        }
        if let value = environment["MEISTER_MODEL_B"], !value.isEmpty {
            next.models.modelB = value
        }
        if let value = environment["MEISTER_JUDGE_MODEL"], !value.isEmpty {
            next.judgeModel = value
        }
        if let value = environment["MEISTER_EMBEDDING_MODEL"], !value.isEmpty {
            next.embeddings.model = value
        }
        if let value = environment["MEISTER_RULE_TOKEN_BUDGET"], let budget = Int(value) {
            next.limits.ruleTokenBudget = budget
        }
        return next
    }

    var settingsDTO: SettingsDTO {
        SettingsDTO(
            bind: bind,
            port: port,
            models: models,
            judgeModel: judgeModel,
            opencodeImage: opencodeImage,
            limits: limits
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
    var limits: Limits

    enum CodingKeys: String, CodingKey {
        case bind, port, models
        case judgeModel = "judge_model"
        case opencodeImage = "opencode_image"
        case limits
    }
}

private struct MeisterConfigKey: StorageKey {
    typealias Value = MeisterConfig
}

extension Application {
    var meisterConfig: MeisterConfig {
        get {
            guard let value = storage[MeisterConfigKey.self] else {
                fatalError("MeisterConfig missing; call configure(_:config:) first")
            }
            return value
        }
        set { storage[MeisterConfigKey.self] = newValue }
    }
}
