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

    public init(
        model: String,
        dimensions: Int,
        endpoint: URL = URL(string: "https://api.openai.com/v1/embeddings")!,
        apiKey: String
    ) {
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
        let body: [String: Any] = ["model": model, "input": texts]
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

public enum EmbeddingClientFactory: Sendable {
    public static func fromEnvironment(
        model: String,
        dimensions: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (any EmbeddingClient)? {
        let resolved = environment["MEISTER_EMBEDDING_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? model
        if let key = environment["OPENAI_API_KEY"], !key.isEmpty {
            return HTTPEmbeddingClient(model: resolved, dimensions: dimensions, apiKey: key)
        }
        return nil
    }
}
