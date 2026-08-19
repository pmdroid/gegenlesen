import Foundation

public struct JobFile: Codable, Sendable, Equatable {
    public var jobID: JobID
    public var path: String
    public var sha256: String?
    public var status: FileChangeStatus
    public var oldPath: String?
    public var language: Language?
    public var bytes: Int?

    public enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case path, sha256, status
        case oldPath = "old_path"
        case language, bytes
    }

    public init(
        jobID: JobID,
        path: String,
        sha256: String? = nil,
        status: FileChangeStatus,
        oldPath: String? = nil,
        language: Language? = nil,
        bytes: Int? = nil
    ) {
        self.jobID = jobID
        self.path = path
        self.sha256 = sha256
        self.status = status
        self.oldPath = oldPath
        self.language = language
        self.bytes = bytes
    }
}
