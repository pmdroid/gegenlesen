import Foundation

public protocol EmbeddingClient: Sendable {
    var model: String { get }
    var dimensions: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public struct HashEmbeddingClient: EmbeddingClient {
    public var model: String
    public var dimensions: Int

    public init(model: String = "hash", dimensions: Int = 32) {
        self.model = model
        self.dimensions = dimensions
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { EmbeddingVector.hashEmbedding($0, dimensions: dimensions) }
    }
}

public struct HTTPEmbeddingClient: EmbeddingClient {
    public var model: String
    public var dimensions: Int
    public var endpoint: URL
    public var apiKey: String

    public init(model: String, dimensions: Int, endpoint: URL, apiKey: String) {
        self.model = model
        self.dimensions = dimensions
        self.endpoint = endpoint
        self.apiKey = apiKey
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "input": texts,
            "dimensions": dimensions,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw EmbeddingError.requestFailed
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]]
        else {
            throw EmbeddingError.badResponse
        }
        return try rows.sorted { lhs, rhs in
            (lhs["index"] as? Int ?? 0) < (rhs["index"] as? Int ?? 0)
        }.map { row in
            guard let vector = row["embedding"] as? [Double] else {
                throw EmbeddingError.badResponse
            }
            return vector.map { Float($0) }
        }
    }
}

public enum EmbeddingError: Error, Sendable {
    case requestFailed
    case badResponse
}

public struct EmbeddingTarget: Sendable, Equatable {
    public var model: String
    public var endpoint: URL
    public var apiKey: String

    public init(model: String, endpoint: URL, apiKey: String) {
        self.model = model
        self.endpoint = endpoint
        self.apiKey = apiKey
    }
}

public enum EmbeddingClientFactory: Sendable {
    public static let openAIEndpoint = URL(string: "https://api.openai.com/v1/embeddings")!
    public static let openRouterEndpoint = URL(string: "https://openrouter.ai/api/v1/embeddings")!

    public static func resolveTarget(
        model: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> EmbeddingTarget? {
        let resolved = environment["GEGENLESEN_EMBEDDING_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? model
        let override = environment["GEGENLESEN_EMBEDDING_URL"].flatMap { URL(string: $0) }
        let openAIKey = nonempty(environment["OPENAI_API_KEY"])
        let openRouterKey = nonempty(environment["OPENROUTER_API_KEY"])

        if let override {
            let host = override.host?.lowercased() ?? ""
            if host.contains("openrouter.ai"), let key = openRouterKey {
                return EmbeddingTarget(model: resolved, endpoint: override, apiKey: key)
            }
            if let key = openAIKey ?? openRouterKey {
                return EmbeddingTarget(
                    model: host.contains("api.openai.com") ? stripOpenAIPrefix(resolved) : resolved,
                    endpoint: override,
                    apiKey: key
                )
            }
            return nil
        }

        if resolved.hasPrefix("openrouter/"), let key = openRouterKey {
            return EmbeddingTarget(
                model: String(resolved.dropFirst("openrouter/".count)),
                endpoint: openRouterEndpoint,
                apiKey: key
            )
        }
        if let key = openRouterKey, resolved.contains("/"), !resolved.hasPrefix("openai/") {
            return EmbeddingTarget(model: resolved, endpoint: openRouterEndpoint, apiKey: key)
        }
        if let key = openAIKey {
            return EmbeddingTarget(
                model: stripOpenAIPrefix(resolved),
                endpoint: openAIEndpoint,
                apiKey: key
            )
        }
        if let key = openRouterKey {
            return EmbeddingTarget(model: resolved, endpoint: openRouterEndpoint, apiKey: key)
        }
        return nil
    }

    public static func fromEnvironment(
        model: String,
        dimensions: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (any EmbeddingClient)? {
        guard let target = resolveTarget(model: model, environment: environment) else {
            return nil
        }
        return HTTPEmbeddingClient(
            model: target.model,
            dimensions: dimensions,
            endpoint: target.endpoint,
            apiKey: target.apiKey
        )
    }

    public static func stripOpenAIPrefix(_ model: String) -> String {
        if model.hasPrefix("openai/") {
            return String(model.dropFirst("openai/".count))
        }
        return model
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
