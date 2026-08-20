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

struct LearningDTO: Content {
    var id: String
    var jobID: JobID?
    var kind: LearningKind
    var status: LearningStatus
    var title: String
    var body: String
    var judged: Bool?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case jobID = "job_id"
        case kind, status, title, body, judged
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
        try container.encode(createdAt, forKey: .createdAt)
    }

    init(learning: Learning) {
        id = learning.id
        jobID = learning.jobID
        kind = learning.kind
        status = learning.status
        title = learning.title
        body = learning.body
        judged = Self.payloadBool(learning.payloadJSON, key: "judged")
        createdAt = learning.createdAt
    }

    private static func payloadBool(_ raw: String?, key: String) -> Bool? {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
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
}
