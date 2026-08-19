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
}
