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

    private static func containsNoFindingsFile(_ text: String?) -> Bool {
        text?.contains("no_findings_file") == true
    }

    private static func looksLikeProviderAuth(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        if text.contains("provider_auth") { return true }
        let markers = [
            "\"status\":401", "\"status\": 401",
            "\"status\":403", "\"status\": 403",
            "\"code\":401", "\"code\": 401",
            "\"code\":403", "\"code\": 403",
            "HTTP 401", "HTTP 403",
        ]
        return markers.contains { text.contains($0) }
    }
}
