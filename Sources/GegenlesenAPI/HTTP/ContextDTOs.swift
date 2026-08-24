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
    var repository: String?

    enum CodingKeys: String, CodingKey {
        case title, body
        case pathGlobs = "path_globs"
        case alwaysInclude = "always_include"
        case repository
    }
}

struct ContextNoteDTO: Content {
    var id: String
    var kind: ContextNoteKind
    var title: String
    var body: String
    var pathGlobs: [String]
    var alwaysInclude: Bool
    var repository: String?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body
        case pathGlobs = "path_globs"
        case alwaysInclude = "always_include"
        case repository
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(pathGlobs, forKey: .pathGlobs)
        try container.encode(alwaysInclude, forKey: .alwaysInclude)
        try container.encodeNilIfNeeded(repository, forKey: .repository)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    init(note: ContextNote) {
        id = note.id
        kind = note.kind
        title = note.title
        body = note.body
        pathGlobs = note.pathGlobs
        alwaysInclude = note.alwaysInclude
        repository = note.repository
        createdAt = note.createdAt
        updatedAt = note.updatedAt
    }
}

struct LearningListResponse: Content {
    var learnings: [LearningDTO]
}

struct LearningDismissRequest: Content {
    var reason: String?
    var comment: String?
}

struct LearningDTO: Content {
    var id: String
    var jobID: JobID?
    var kind: LearningKind
    var status: LearningStatus
    var title: String
    var body: String
    var judged: Bool?
    var dismissReason: LearningDismissReason?
    var dismissComment: String?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case jobID = "job_id"
        case kind, status, title, body, judged
        case dismissReason = "dismiss_reason"
        case dismissComment = "dismiss_comment"
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
        try container.encodeNilIfNeeded(judged, forKey: .judged)
        try container.encodeNilIfNeeded(dismissReason, forKey: .dismissReason)
        try container.encodeNilIfNeeded(dismissComment, forKey: .dismissComment)
        try container.encode(createdAt, forKey: .createdAt)
    }

    init(learning: Learning) {
        id = learning.id
        jobID = learning.jobID
        kind = learning.kind
        status = learning.status
        title = learning.title
        body = learning.body
        judged = learning.payloadBool("judged")
        dismissReason = learning.dismissReason
        dismissComment = learning.dismissComment
        createdAt = learning.createdAt
    }
}
