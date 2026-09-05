import Foundation

public struct JobEvent: Sendable, Equatable {
    public var id: Int
    public var jobID: JobID
    public var ts: Date
    public var level: EventLevel
    public var message: String
    public var payloadJSON: String?

    public init(
        id: Int,
        jobID: JobID,
        ts: Date,
        level: EventLevel,
        message: String,
        payloadJSON: String? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.ts = ts
        self.level = level
        self.message = message
        self.payloadJSON = payloadJSON
    }

    public static func payloadJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }
}

public enum ReviewFailureClass: String, Sendable, Equatable {
    case providerAuth = "provider_auth"
    case providerRateLimited = "provider_rate_limited"
    case containerStartFailed = "container_start_failed"
    case noFindingsFile = "no_findings_file"
    case reviewerFailed = "reviewer_failed"

    public static func classify(errorMessage: String?, payloadJSON: String?) -> ReviewFailureClass {
        if looksLikeProviderAuth(errorMessage) || looksLikeProviderAuth(payloadJSON) {
            return .providerAuth
        }
        if providerRateLimitMarker(in: errorMessage) != nil || providerRateLimitMarker(in: payloadJSON) != nil {
            return .providerRateLimited
        }
        if containsToken("container_start_failed", errorMessage) || containsToken("container_start_failed", payloadJSON) {
            return .containerStartFailed
        }
        if containsNoFindingsFile(errorMessage) || containsNoFindingsFile(payloadJSON) {
            return .noFindingsFile
        }
        return .reviewerFailed
    }

    /// Quota/throttle errors from the provider, e.g.
    /// `Error: RetriableError: [resource_exhausted]` in a reviewer transcript.
    /// Tokens are specific so code quoted from the repo under review cannot
    /// trip them (a bare 429 or "rate limit" in source would).
    public static func providerRateLimitMarker(in text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        for marker in ["provider_rate_limited", "resource_exhausted", "retriableerror", "rate_limit_exceeded"] {
            if lowered.contains(marker) {
                return marker
            }
        }
        return providerAuthHTTPStatus429(in: text)
    }

    private static func providerAuthHTTPStatus429(in text: String) -> String? {
        for marker in ["\"status\":429", "\"status\": 429", "\"statusCode\":429", "\"statusCode\": 429", "HTTP 429"] {
            if text.contains(marker) {
                return marker
            }
        }
        return nil
    }

    /// 401/403 from OpenCode/OpenRouter HTTP or `opencode run` stdout/stderr. Not a host LLM call.
    public static func providerAuthHTTPStatus(in text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        // OpenRouter 401 body. Bare "User not found" in a reviewer transcript
        // that quoted the code under review is not provider auth.
        if text.contains("User not found"),
           text.contains("401") || text.contains("\"error\"") || text.contains("\"statusCode\"") {
            return 401
        }
        for code in [401, 403] {
            let markers = [
                "\"status\":\(code)", "\"status\": \(code)",
                "\"statusCode\":\(code)", "\"statusCode\": \(code)",
                "\"code\":\(code)", "\"code\": \(code)",
                "HTTP \(code)",
            ]
            if markers.contains(where: { text.contains($0) }) {
                return code
            }
        }
        return nil
    }

    private static func containsNoFindingsFile(_ text: String?) -> Bool {
        containsToken("no_findings_file", text)
    }

    private static func containsToken(_ token: String, _ text: String?) -> Bool {
        text?.contains(token) == true
    }

    private static func looksLikeProviderAuth(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        if text.contains("provider_auth") { return true }
        return providerAuthHTTPStatus(in: text) != nil
    }
}
