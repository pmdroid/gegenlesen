import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Vapor

struct OpenRouterModelDTO: Content, Sendable, Equatable {
    var id: String
    var name: String
    var description: String?
    var contextLength: Int?
    var promptPrice: String?
    var free: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, free
        case contextLength = "context_length"
        case promptPrice = "prompt_price"
    }
}

struct OpenRouterModelList: Content, Sendable, Equatable {
    var models: [OpenRouterModelDTO]
    var total: Int
    var query: String?
    var category: String?
    var sort: String?
    var free: Bool
}

struct OpenRouterModelQuery: Sendable {
    var q: String?
    var category: String?
    var sort: String
    var limit: Int
    var free: Bool

    static let sorts: Set<String> = [
        "most-popular",
        "newest",
        "top-weekly",
        "pricing-low-to-high",
        "coding-high-to-low",
        "intelligence-high-to-low",
        "agentic-high-to-low",
    ]

    static let categories: Set<String> = [
        "programming",
        "technology",
        "academia",
        "science",
        "legal",
        "translation",
    ]

    init(q: String?, category: String?, sort: String?, limit: Int?, free: Bool = false) {
        let trimmedQ = q?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.q = (trimmedQ?.isEmpty == false) ? trimmedQ : nil
        let trimmedCat = category?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedCat, Self.categories.contains(trimmedCat) {
            self.category = trimmedCat
        } else {
            self.category = nil
        }
        let trimmedSort = sort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "most-popular"
        self.sort = Self.sorts.contains(trimmedSort) ? trimmedSort : "most-popular"
        self.limit = min(max(limit ?? 80, 1), 200)
        self.free = free
    }
}

enum OpenRouterModels {
    static let canned: [OpenRouterModelDTO] = [
        .init(
            id: "openrouter/deepseek/deepseek-v4-flash",
            name: "DeepSeek V4 Flash",
            description: "canned",
            contextLength: 128_000,
            promptPrice: "0.000001",
            free: false
        ),
        .init(
            id: "openrouter/google/gemini-3.7-flash",
            name: "Gemini 3.7 Flash",
            description: "canned",
            contextLength: 128_000,
            promptPrice: "0.000001",
            free: false
        ),
        .init(
            id: "openrouter/openai/gpt-5.6-terra",
            name: "GPT-5.6 Terra",
            description: "canned",
            contextLength: 128_000,
            promptPrice: "0.000001",
            free: false
        ),
        .init(
            id: "openrouter/google/gemma-4-31b-it:free",
            name: "Gemma 4 31B (free)",
            description: "canned",
            contextLength: 128_000,
            promptPrice: "0",
            free: true
        ),
    ]

    static func openCodeID(_ raw: String) -> String {
        if raw.hasPrefix("openrouter/") { return raw }
        return "openrouter/\(raw)"
    }

    static func list(key: String, query: OpenRouterModelQuery) async throws -> OpenRouterModelList {
        var parts = URLComponents(string: "https://openrouter.ai/api/v1/models")!
        var items: [URLQueryItem] = [
            .init(name: "output_modalities", value: "text"),
            .init(name: "sort", value: query.sort),
        ]
        if let q = query.q {
            items.append(.init(name: "q", value: q))
        }
        if query.free {
            items.append(.init(name: "max_price", value: "0"))
            items.append(.init(name: "max_output_price", value: "0"))
        }
        if let category = query.category {
            // OpenRouter 400s if category is combined with limit or offset.
            items.append(.init(name: "category", value: category))
        } else {
            items.append(.init(name: "limit", value: String(query.limit)))
        }
        parts.queryItems = items
        guard let url = parts.url else {
            throw APIError.unprocessable("could not build OpenRouter models URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw APIError.unprocessable("OpenRouter rejected the API key")
        }
        if status < 200 || status >= 300 {
            throw APIError.unprocessable(openRouterErrorMessage(data, status: status))
        }
        let decoded = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
        let models = decoded.data.map { item in
            let id = openCodeID(item.id)
            return OpenRouterModelDTO(
                id: id,
                name: item.name,
                description: item.description,
                contextLength: item.contextLength,
                promptPrice: item.pricing?.prompt,
                free: isFree(id: item.id, prompt: item.pricing?.prompt, completion: item.pricing?.completion)
            )
        }
        return OpenRouterModelList(
            models: models,
            total: decoded.totalCount ?? models.count,
            query: query.q,
            category: query.category,
            sort: query.sort,
            free: query.free
        )
    }

    private static func isFree(id: String, prompt: String?, completion: String?) -> Bool {
        if id.contains(":free") { return true }
        let promptPrice = Double(prompt ?? "") ?? -1
        let completionPrice = Double(completion ?? "") ?? -1
        return promptPrice == 0 && completionPrice == 0
    }
}

private struct OpenRouterModelsResponse: Decodable {
    var data: [Item]
    var totalCount: Int?

    enum CodingKeys: String, CodingKey {
        case data
        case totalCount = "total_count"
    }

    struct Item: Decodable {
        var id: String
        var name: String
        var description: String?
        var contextLength: Int?
        var pricing: Pricing?

        enum CodingKeys: String, CodingKey {
            case id, name, description, pricing
            case contextLength = "context_length"
        }
    }

    struct Pricing: Decodable {
        var prompt: String?
        var completion: String?
    }
}

private struct OpenRouterErrorBody: Decodable {
    var error: Payload?
    struct Payload: Decodable {
        var message: String?
    }
}

private func openRouterErrorMessage(_ data: Data, status: Int) -> String {
    if let parsed = try? JSONDecoder().decode(OpenRouterErrorBody.self, from: data),
       let message = parsed.error?.message, !message.isEmpty {
        return message
    }
    return "could not list OpenRouter models (\(status))"
}
