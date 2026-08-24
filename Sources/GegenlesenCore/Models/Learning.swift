import Foundation

public struct Learning: Sendable, Equatable {
    public var id: String
    public var jobID: JobID?
    public var kind: LearningKind
    public var status: LearningStatus
    public var title: String
    public var body: String
    public var payloadJSON: String?
    public var createdAt: Date
    public var resolvedAt: Date?

    public init(
        id: String = UUID().uuidString.lowercased(),
        jobID: JobID? = nil,
        kind: LearningKind,
        status: LearningStatus = .pending,
        title: String,
        body: String,
        payloadJSON: String? = nil,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.kind = kind
        self.status = status
        self.title = title
        self.body = body
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }

    public var dismissReason: LearningDismissReason? {
        payloadString("dismiss_reason").flatMap(LearningDismissReason.init(rawValue:))
    }

    public var dismissComment: String? {
        payloadString("dismiss_comment")
    }

    public mutating func applyDismiss(reason: LearningDismissReason?, comment: String?) {
        var updates: [String: Any] = [:]
        if let reason {
            updates["dismiss_reason"] = reason.rawValue
        }
        if let comment {
            updates["dismiss_comment"] = comment
        }
        guard !updates.isEmpty else { return }
        mergePayload(updates)
    }

    public func payloadString(_ key: String) -> String? {
        payloadObject()[key] as? String
    }

    public func payloadBool(_ key: String) -> Bool? {
        let object = payloadObject()
        if let value = object[key] as? Bool { return value }
        if let value = object[key] as? String {
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    public mutating func mergePayload(_ values: [String: Any]) {
        var object = payloadObject()
        for (key, value) in values {
            object[key] = value
        }
        payloadJSON = Self.encodePayload(object)
    }

    private func payloadObject() -> [String: Any] {
        guard let payloadJSON, let data = payloadJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func encodePayload(_ object: [String: Any]) -> String? {
        guard !object.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }
}
