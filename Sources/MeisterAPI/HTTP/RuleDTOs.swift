import Foundation
import MeisterCore
import Vapor

struct RuleListResponse: Content {
    var rules: [RuleDTO]
}

struct RuleUpsert: Content {
    var id: RuleID?
    var title: String
    var severity: Severity
    var kind: RuleKind
    var enabled: Bool?
    var languages: [String]
    var pathGlobs: [String]
    var payload: RulePayload
    var examples: [RuleExample]?
    var body: String?

    enum CodingKeys: String, CodingKey {
        case id, title, severity, kind, enabled, languages
        case pathGlobs = "path_globs"
        case payload, examples, body
    }
}

struct RuleDTO: Content {
    var id: RuleID
    var title: String
    var severity: Severity
    var kind: RuleKind
    var enabled: Bool
    var deletedAt: Date?
    var provenance: RuleProvenance
    var languages: [String]
    var pathGlobs: [String]
    var payload: RulePayload
    var examples: [RuleExample]
    var sourcePRRefs: [String]
    var promotedFromRuleID: RuleID?
    var body: String
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, severity, kind, enabled
        case deletedAt = "deleted_at"
        case provenance, languages
        case pathGlobs = "path_globs"
        case payload, examples
        case sourcePRRefs = "source_pr_refs"
        case promotedFromRuleID = "promoted_from_rule_id"
        case body
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(severity, forKey: .severity)
        try container.encode(kind, forKey: .kind)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeNilIfNeeded(deletedAt, forKey: .deletedAt)
        try container.encode(provenance, forKey: .provenance)
        try container.encode(languages, forKey: .languages)
        try container.encode(pathGlobs, forKey: .pathGlobs)
        try container.encode(payload, forKey: .payload)
        try container.encode(examples, forKey: .examples)
        try container.encode(sourcePRRefs, forKey: .sourcePRRefs)
        try container.encodeNilIfNeeded(promotedFromRuleID, forKey: .promotedFromRuleID)
        try container.encode(body, forKey: .body)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    init(rule: Rule) {
        self.id = rule.id
        self.title = rule.title
        self.severity = rule.severity
        self.kind = rule.kind
        self.enabled = rule.enabled
        self.deletedAt = rule.deletedAt
        self.provenance = rule.provenance
        self.languages = rule.languages
        self.pathGlobs = rule.pathGlobs
        self.payload = rule.payload
        self.examples = rule.examples
        self.sourcePRRefs = rule.sourcePRRefs
        self.promotedFromRuleID = rule.promotedFromRuleID
        self.body = rule.body
        self.createdAt = rule.createdAt
        self.updatedAt = rule.updatedAt
    }
}