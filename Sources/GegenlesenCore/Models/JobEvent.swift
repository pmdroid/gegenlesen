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
}
