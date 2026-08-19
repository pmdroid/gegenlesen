import Foundation

public struct CorpusItem: Sendable, Equatable {
    public var id: String
    public var sourceLabel: String
    public var title: String?
    public var body: String?
    public var commentsJSON: String?
    public var patchRelpath: String
    public var minedAt: Date?
    public var createdAt: Date

    public init(
        id: String,
        sourceLabel: String,
        title: String? = nil,
        body: String? = nil,
        commentsJSON: String? = nil,
        patchRelpath: String,
        minedAt: Date? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.sourceLabel = sourceLabel
        self.title = title
        self.body = body
        self.commentsJSON = commentsJSON
        self.patchRelpath = patchRelpath
        self.minedAt = minedAt
        self.createdAt = createdAt
    }
}

public enum MineSource: String, Codable, Sendable, Equatable {
    case corpus
    case job
    case harvest
}

public struct MineJobSpec: Codable, Sendable, Equatable {
    public var source: MineSource
    public var itemIDs: [String]?
    public var sourceJobID: JobID?

    public init(source: MineSource, itemIDs: [String]? = nil, sourceJobID: JobID? = nil) {
        self.source = source
        self.itemIDs = itemIDs
        self.sourceJobID = sourceJobID
    }

    enum CodingKeys: String, CodingKey {
        case source
        case itemIDs = "item_ids"
        case sourceJobID = "source_job_id"
    }
}
