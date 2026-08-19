import Foundation
import Vapor

enum ModelsRoute {
    static func register(_ app: Application) {
        app.get("api", "models", use: list)
    }

    private static func list(_ req: Request) async throws -> OpenRouterModelList {
        let query = OpenRouterModelQuery(
            q: req.query[String.self, at: "q"],
            category: req.query[String.self, at: "category"],
            sort: req.query[String.self, at: "sort"],
            limit: req.query[Int.self, at: "limit"],
            free: req.query[Bool.self, at: "free"] ?? false
        )
        guard let key = resolvedKey(req) else {
            throw APIError.unprocessable("OpenRouter API key is required")
        }
        if req.application.gegenlesenJobs.skipAgent {
            let filtered = OpenRouterModels.canned.filter { model in
                if query.free && !model.free { return false }
                guard let q = query.q?.lowercased() else { return true }
                return model.id.lowercased().contains(q) || model.name.lowercased().contains(q)
            }
            return OpenRouterModelList(
                models: filtered,
                total: filtered.count,
                query: query.q,
                category: query.category,
                sort: query.sort,
                free: query.free
            )
        }
        return try await OpenRouterModels.list(key: key, query: query)
    }

    private static func resolvedKey(_ req: Request) -> String? {
        if let header = req.headers.first(name: "X-OpenRouter-Key") {
            let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let stored = req.application.gegenlesenConfig.openrouterApiKey, !stored.isEmpty {
            return stored
        }
        let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""
        return env.isEmpty ? nil : env
    }
}
