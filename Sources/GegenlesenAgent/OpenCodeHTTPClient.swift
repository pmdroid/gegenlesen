import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GegenlesenCore

public enum OpenCodeHTTPError: Error, Sendable, Equatable, CustomStringConvertible {
    case providerAuth(status: Int, body: String)

    public var description: String {
        switch self {
        case .providerAuth(let status, let body):
            return "provider_auth status=\(status) \(body)"
        }
    }

    public static func classify(status: Int, body: Data) -> OpenCodeHTTPError? {
        let snippet = String(data: body, encoding: .utf8).map { String($0.prefix(500)) } ?? ""
        // HTTP status only. Do not sniff 2xx bodies — reviewer output quoting
        // "HTTP 401" / "User not found" is not a provider auth failure.
        if status == 401 || status == 403 {
            return .providerAuth(status: status, body: snippet)
        }
        return nil
    }
}

public protocol OpenCodeHTTPClienting: Sendable {
    func waitUntilHealthy(baseURL: URL, password: String, timeout: Duration) async -> Bool
    func createSession(baseURL: URL, password: String, title: String) async throws -> String
    func sendReview(
        baseURL: URL,
        password: String,
        sessionID: String,
        agent: String,
        model: String,
        prompt: String,
        filePaths: [String],
        timeout: Duration
    ) async throws
    func abort(baseURL: URL, password: String, sessionID: String) async
}

public struct OpenCodeHTTPClient: OpenCodeHTTPClienting {
    public var username: String
    public var shortTimeout: TimeInterval

    public init(username: String = "opencode", shortTimeout: TimeInterval = 10) {
        self.username = username
        self.shortTimeout = shortTimeout
    }

    public func waitUntilHealthy(baseURL: URL, password: String, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        let url = baseURL.appending(path: "global/health")
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            if let (data, response) = try? await request(
                url: url,
                method: "GET",
                password: password,
                body: nil,
                timeout: shortTimeout
            ),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["healthy"] as? Bool == true {
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    public func createSession(baseURL: URL, password: String, title: String) async throws -> String {
        let url = baseURL.appending(path: "session")
        let payload = try JSONSerialization.data(withJSONObject: ["title": title])
        let (data, _) = try await request(
            url: url,
            method: "POST",
            password: password,
            body: payload,
            timeout: shortTimeout
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let id = object?["id"] as? String { return id }
        if let nested = object?["session"] as? [String: Any], let id = nested["id"] as? String {
            return id
        }
        throw URLError(.cannotParseResponse)
    }

    public func sendReview(
        baseURL: URL,
        password: String,
        sessionID: String,
        agent: String,
        model: String,
        prompt: String,
        filePaths: [String],
        timeout: Duration
    ) async throws {
        let url = baseURL.appending(path: "session").appending(path: sessionID).appending(path: "message")
        let split = OpenCodeConfig.splitModel(model)
        var parts: [[String: Any]] = [["type": "text", "text": prompt]]
        for path in filePaths {
            parts.append(["type": "file", "path": path])
        }
        let body: [String: Any] = [
            "agent": agent,
            "model": [
                "providerID": split.providerID,
                "modelID": split.modelID,
            ],
            "parts": parts,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await request(
            url: url,
            method: "POST",
            password: password,
            body: payload,
            timeout: timeout.timeInterval
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let error = OpenCodeHTTPError.classify(status: status, body: data) {
            throw error
        }
    }

    public func abort(baseURL: URL, password: String, sessionID: String) async {
        let url = baseURL.appending(path: "session").appending(path: sessionID).appending(path: "abort")
        _ = try? await request(
            url: url,
            method: "POST",
            password: password,
            body: Data("{}".utf8),
            timeout: shortTimeout
        )
        let delete = baseURL.appending(path: "session").appending(path: sessionID)
        _ = try? await request(url: delete, method: "DELETE", password: password, body: nil, timeout: shortTimeout)
    }

    private func request(
        url: URL,
        method: String,
        password: String,
        body: Data?,
        timeout: TimeInterval
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw OpenCodeHTTPError.classify(status: http.statusCode, body: data)
                ?? .providerAuth(status: http.statusCode, body: "")
        }
        return (data, response)
    }
}

public struct UnhealthyOpenCodeHTTP: OpenCodeHTTPClienting {
    public init() {}

    public func waitUntilHealthy(baseURL: URL, password: String, timeout: Duration) async -> Bool {
        false
    }

    public func createSession(baseURL: URL, password: String, title: String) async throws -> String {
        throw URLError(.cannotConnectToHost)
    }

    public func sendReview(
        baseURL: URL,
        password: String,
        sessionID: String,
        agent: String,
        model: String,
        prompt: String,
        filePaths: [String],
        timeout: Duration
    ) async throws {
        throw URLError(.cannotConnectToHost)
    }

    public func abort(baseURL: URL, password: String, sessionID: String) async {}
}
