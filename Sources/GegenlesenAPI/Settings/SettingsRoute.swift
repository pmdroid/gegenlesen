import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
            let a = models.modelA.trimmingCharacters(in: .whitespacesAndNewlines)
            let b = models.modelB.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !a.isEmpty, !b.isEmpty else {
                throw APIError.unprocessable("both reviewer models are required")
            }
            next.models = ModelSlots(modelA: a, modelB: b)
        }
        if let judge = body.judgeModel {
            let trimmed = judge.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw APIError.unprocessable("judge model is required")
            }
            next.judgeModel = trimmed
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
