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
    var limits: Limits

    enum CodingKeys: String, CodingKey {
        case bind, port
        case dataDir = "data_dir"
        case models
        case judgeModel = "judge_model"
        case opencodeImage = "opencode_image"
        case limits
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
