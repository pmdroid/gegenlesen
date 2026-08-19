import Foundation
import GegenlesenCore
import Vapor

struct ContextNoteListResponse: Content {
    var notes: [ContextNoteDTO]
}

struct ContextNoteUpsert: Content {
    var title: String
    var body: String
    var pathGlobs: [String]?
    var alwaysInclude: Bool?

    enum CodingKeys: String, CodingKey {
        case title, body
        case pathGlobs = "path_globs"
        case alwaysInclude = "always_include"
    }
}

struct ContextNoteDTO: Content {
    var id: String
    var kind: ContextNoteKind
    var title: String
    var body: String
    var pathGlobs: [String]
    var alwaysInclude: Bool
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body
        case pathGlobs = "path_globs"
        case alwaysInclude = "always_include"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(note: ContextNote) {
        id = note.id
        kind = note.kind
        title = note.title
        body = note.body
        pathGlobs = note.pathGlobs
        alwaysInclude = note.alwaysInclude
        createdAt = note.createdAt
        updatedAt = note.updatedAt
    }
}

struct LearningListResponse: Content {
    var learnings: [LearningDTO]
}

struct LearningDTO: Content {
    var id: String
    var jobID: JobID?
    var kind: LearningKind
    var status: LearningStatus
    var title: String
    var body: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case jobID = "job_id"
        case kind, status, title, body
        case createdAt = "created_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeNilIfNeeded(jobID, forKey: .jobID)
        try container.encode(kind, forKey: .kind)
        try container.encode(status, forKey: .status)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(createdAt, forKey: .createdAt)
    }

    init(learning: Learning) {
        id = learning.id
        jobID = learning.jobID
        kind = learning.kind
        status = learning.status
        title = learning.title
        body = learning.body
        createdAt = learning.createdAt
    }
}
