import Foundation

public enum AgentEngineID {
    public static let opencode = "opencode"
}

public struct JobTimings: Codable, Sendable, Equatable {
    public var unpackMS: Int?
    public var identifyMS: Int?
    public var deterministicMS: Int?
    public var reviewMS: Int?
    public var judgeMS: Int?

    public init(
        unpackMS: Int? = nil,
        identifyMS: Int? = nil,
        deterministicMS: Int? = nil,
        reviewMS: Int? = nil,
        judgeMS: Int? = nil
    ) {
        self.unpackMS = unpackMS
        self.identifyMS = identifyMS
        self.deterministicMS = deterministicMS
        self.reviewMS = reviewMS
        self.judgeMS = judgeMS
    }

    enum CodingKeys: String, CodingKey {
        case unpackMS = "unpack_ms"
        case identifyMS = "identify_ms"
        case deterministicMS = "deterministic_ms"
        case reviewMS = "review_ms"
        case judgeMS = "judge_ms"
    }
}

public struct JobSummary: Codable, Sendable, Equatable {
    public var new: Int
    public var stillOpen: Int
    public var resolved: Int
    public var relocated: Int
    public var dropped: Int

    public init(new: Int = 0, stillOpen: Int = 0, resolved: Int = 0, relocated: Int = 0, dropped: Int = 0) {
        self.new = new
        self.stillOpen = stillOpen
        self.resolved = resolved
        self.relocated = relocated
        self.dropped = dropped
    }

    public static let zero = JobSummary()

    enum CodingKeys: String, CodingKey {
        case new
        case stillOpen = "still_open"
        case resolved, relocated, dropped
    }
}

public struct Job: Sendable, Equatable {
    public var id: JobID
    public var createdAt: Date
    public var updatedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var status: JobStatus
    public var scope: JobScope
    public var parentJobID: JobID?
    public var title: String?
    public var repository: String?
    public var reviewerAEngine: String
    public var reviewerAModelID: String
    public var reviewerBEngine: String
    public var reviewerBModelID: String
    public var judgeEngine: String
    public var judgeModelID: String
    public var baseSHA: String?
    public var headSHA: String?
    public var defaultBranch: String?
    public var archiveSHA256: String?
    public var archiveBytes: Int?
    public var fileCount: Int?
    public var errorMessage: String?
    public var containerName: String?
    public var containerNameA: String?
    public var containerNameB: String?
    public var timings: JobTimings?
    public var risk: RiskAssessment?

    public init(
        id: JobID,
        createdAt: Date,
        updatedAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        status: JobStatus,
        scope: JobScope,
        parentJobID: JobID? = nil,
        title: String? = nil,
        repository: String? = nil,
        reviewerAEngine: String = AgentEngineID.opencode,
        reviewerAModelID: String,
        reviewerBEngine: String = AgentEngineID.opencode,
        reviewerBModelID: String,
        judgeEngine: String = AgentEngineID.opencode,
        judgeModelID: String,
        baseSHA: String? = nil,
        headSHA: String? = nil,
        defaultBranch: String? = nil,
        archiveSHA256: String? = nil,
        archiveBytes: Int? = nil,
        fileCount: Int? = nil,
        errorMessage: String? = nil,
        containerName: String? = nil,
        containerNameA: String? = nil,
        containerNameB: String? = nil,
        timings: JobTimings? = nil,
        risk: RiskAssessment? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.scope = scope
        self.parentJobID = parentJobID
        self.title = title
        self.repository = repository
        self.reviewerAEngine = reviewerAEngine
        self.reviewerAModelID = reviewerAModelID
        self.reviewerBEngine = reviewerBEngine
        self.reviewerBModelID = reviewerBModelID
        self.judgeEngine = judgeEngine
        self.judgeModelID = judgeModelID
        self.baseSHA = baseSHA
        self.headSHA = headSHA
        self.defaultBranch = defaultBranch
        self.archiveSHA256 = archiveSHA256
        self.archiveBytes = archiveBytes
        self.fileCount = fileCount
        self.errorMessage = errorMessage
        self.containerName = containerName
        self.containerNameA = containerNameA
        self.containerNameB = containerNameB
        self.timings = timings
        self.risk = risk
    }
}
