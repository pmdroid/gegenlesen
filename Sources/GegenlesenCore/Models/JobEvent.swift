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
    case noFindingsFile = "no_findings_file"
    case reviewerFailed = "reviewer_failed"

    public static func classify(errorMessage: String?, payloadJSON: String?) -> ReviewFailureClass {
        if looksLikeProviderAuth(errorMessage) || looksLikeProviderAuth(payloadJSON) {
            return .providerAuth
        }
        if containsNoFindingsFile(errorMessage) || containsNoFindingsFile(payloadJSON) {
            return .noFindingsFile
        }
        return .reviewerFailed
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
        text?.contains("no_findings_file") == true
    }

    private static func looksLikeProviderAuth(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        if text.contains("provider_auth") { return true }
        return providerAuthHTTPStatus(in: text) != nil
    }
}
