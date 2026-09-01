import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GegenlesenCore
import Vapor

enum SettingsRoute {
    static func register(_ app: Application) {
        app.get("api", "settings") { req in
            req.application.gegenlesenConfig.settingsDTO
        }
        app.put("api", "settings", use: update)
        app.patch("api", "settings", use: update)
    }

    private static func update(_ req: Request) async throws -> SettingsDTO {
        let body = try req.content.decode(SettingsUpdate.self)
        var next = req.application.gegenlesenConfig
        if let models = body.models {
            if let rawModelA = models.modelA {
                let a = rawModelA.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !a.isEmpty else {
                    throw APIError.unprocessable("reviewer A model is required")
                }
                next.models.modelA = a
            }
            if let rawModelB = models.modelB {
                let b = rawModelB.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !b.isEmpty else {
                    throw APIError.unprocessable("reviewer B model is required")
                }
                next.models.modelB = b
            }
            if let rawEngineA = models.engineA {
                let engine = rawEngineA.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !engine.isEmpty else {
                    throw APIError.unprocessable("reviewer A engine is required")
                }
                guard AgentEngineID.isKnown(engine) else {
                    throw APIError.unprocessable("unknown engine: \(engine)")
                }
                next.models.engineA = engine
            }
            if let rawEngineB = models.engineB {
                let engine = rawEngineB.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !engine.isEmpty else {
                    throw APIError.unprocessable("reviewer B engine is required")
                }
                guard AgentEngineID.isKnown(engine) else {
                    throw APIError.unprocessable("unknown engine: \(engine)")
                }
                next.models.engineB = engine
            }
        }
        if let engine = body.judgeEngine {
            let trimmed = engine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw APIError.unprocessable("judge engine is required")
            }
            guard AgentEngineID.isKnown(trimmed) else {
                throw APIError.unprocessable("unknown engine: \(trimmed)")
            }
            next.judgeEngine = trimmed
        }
        if let judge = body.judgeModel {
            let trimmed = judge.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw APIError.unprocessable("judge model is required")
            }
            next.judgeModel = trimmed
        }
        if let miner = body.minerModel {
            let trimmed = miner.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw APIError.unprocessable("miner model is required")
            }
            next.minerModel = trimmed
        }
        if let profiles = body.engineProfiles {
            if let mine = profiles.mine {
                if let engine = mine.engine {
                    let trimmed = engine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        throw APIError.unprocessable("mine engine is required")
                    }
                    guard AgentEngineID.isKnown(trimmed) else {
                        throw APIError.unprocessable("unknown engine: \(trimmed)")
                    }
                    next.engineProfiles.mine.engine = trimmed
                }
                if let model = mine.model {
                    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        throw APIError.unprocessable("mine model is required")
                    }
                    next.engineProfiles.mine.model = trimmed
                }
            }
            if let learn = profiles.learn {
                if let engine = learn.engine {
                    let trimmed = engine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        throw APIError.unprocessable("learn engine is required")
                    }
                    guard AgentEngineID.isKnown(trimmed) else {
                        throw APIError.unprocessable("unknown engine: \(trimmed)")
                    }
                    next.engineProfiles.learn.engine = trimmed
                }
                if let model = learn.model {
                    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        throw APIError.unprocessable("learn model is required")
                    }
                    next.engineProfiles.learn.model = trimmed
                }
            }
        }
        if let risk = body.risk {
            if let mode = risk.mode {
                next.risk.mode = mode
            }
            if let appetite = risk.appetite {
                guard (1...5).contains(appetite) else {
                    throw APIError.unprocessable("risk.appetite must be 1-5")
                }
                next.risk.appetite = appetite
            }
        }
        if let rawKey = body.openrouterApiKey {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw APIError.unprocessable("API key is empty")
            }
            try await verifyOpenRouterKeyIfNeeded(key, skip: req.application.gegenlesenJobs.skipAgent)
            next.openrouterApiKey = key
            setenv("OPENROUTER_API_KEY", key, 1)
        }
        if let rawImage = body.scannerImage {
            let image = rawImage.trimmingCharacters(in: .whitespacesAndNewlines)
            if image.contains(where: \.isNewline) {
                throw APIError.unprocessable("scanner image must be a single line")
            }
            next.scannerImage = image
        }
        if let limits = body.limits {
            if let mine = limits.mineTimeoutSec {
                next.limits.mineTimeoutSec = Limits.clampMineTimeout(mine)
            }
            if let agent = limits.agentTimeoutSec {
                next.limits.agentTimeoutSec = Limits.clampAgentTimeout(agent)
            }
            if let minutes = limits.learnIntervalMinutes {
                next.limits.learnIntervalMinutes = max(0, minutes)
            }
            if let strict = limits.reviewStrictMode {
                next.limits.reviewStrictMode = strict
            }
        }
        if !next.isOpenRouterConfigured() {
            throw APIError.unprocessable("OpenRouter API key is required")
        }
        if let url = req.application.gegenlesenConfigFileURL {
            try next.persist(to: url)
        }
        req.application.gegenlesenConfig = next
        req.application.gegenlesenJobs.apply(next)
        return next.settingsDTO
    }

    private static func verifyOpenRouterKeyIfNeeded(_ key: String, skip: Bool) async throws {
        if skip { return }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/key")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw APIError.unprocessable("OpenRouter rejected the API key")
        }
        if status < 200 || status >= 300 {
            throw APIError.unprocessable("could not check the API key with OpenRouter (\(status))")
        }
    }
}
