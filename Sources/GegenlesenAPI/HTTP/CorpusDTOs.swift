import Foundation
import GegenlesenCore
import Vapor

struct CorpusItemDTO: Content {
    var id: String
    var sourceLabel: String
    var title: String?
    var body: String?
    var commentsJSON: String?
    var patchRelpath: String
    var minedAt: Date?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case sourceLabel = "source_label"
        case title, body
        case commentsJSON = "comments_json"
        case patchRelpath = "patch_relpath"
        case minedAt = "mined_at"
        case createdAt = "created_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceLabel, forKey: .sourceLabel)
        try container.encodeNilIfNeeded(title, forKey: .title)
        try container.encodeNilIfNeeded(body, forKey: .body)
        try container.encodeNilIfNeeded(commentsJSON, forKey: .commentsJSON)
        try container.encode(patchRelpath, forKey: .patchRelpath)
        try container.encodeNilIfNeeded(minedAt, forKey: .minedAt)
        try container.encode(createdAt, forKey: .createdAt)
    }

    init(item: CorpusItem) {
        self.id = item.id
        self.sourceLabel = item.sourceLabel
        self.title = item.title
        self.body = item.body
        self.commentsJSON = item.commentsJSON
        self.patchRelpath = item.patchRelpath
        self.minedAt = item.minedAt
        self.createdAt = item.createdAt
    }
}

struct CorpusListResponse: Content {
    var items: [CorpusItemDTO]
}

struct CorpusAccepted: Content {
    var accepted: Int
}

struct MineRequest: Content {
    var itemIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case itemIDs = "item_ids"
    }
}

struct MineAccepted: Content {
    var jobID: JobID

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
    }
}
