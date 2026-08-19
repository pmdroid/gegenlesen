import Foundation
import GegenlesenCore
import Vapor

enum RulesRoute {
    static func register(_ app: Application) {
        app.get("api", "rules", use: list)
        app.get("api", "rules", ":id", use: detail)
        app.post("api", "rules", use: create)
        app.put("api", "rules", ":id", use: update)
        app.delete("api", "rules", ":id", use: remove)
        app.post("api", "rules", ":id", "promote", use: promote)
        app.post("api", "rules", ":id", "enable", use: enable)
        app.post("api", "rules", ":id", "disable", use: disable)
    }

    static func list(_ req: Request) async throws -> RuleListResponse {
        let filter = try parseFilter(req)
        let rules = try await req.application.gegenlesenStore.listRules(filter)
        return RuleListResponse(rules: rules.map(RuleDTO.init(rule:)))
    }

    static func detail(_ req: Request) async throws -> RuleDTO {
        RuleDTO(rule: try await requireRule(req))
    }

    static func create(_ req: Request) async throws -> Response {
        let upsert = try decodeUpsert(req)
        let now = Date()
        var id = upsert.id ?? RuleID.slug(from: upsert.title)
        if !id.isValid {
            throw APIError.badRequest("rule id must be kebab-case [a-z0-9][a-z0-9-]{1,126}")
        }
        if try await req.application.gegenlesenStore.rule(id: id) != nil {
            if upsert.id != nil {
                throw APIError.conflict("rule already exists")
            }
            id = try await uniqueID(base: id, store: req.application.gegenlesenStore)
        }
        let rule = Rule(
            id: id,
            title: upsert.title,
            severity: upsert.severity,
            kind: upsert.kind,
            enabled: upsert.enabled ?? true,
            provenance: .handwritten,
            languages: upsert.languages,
            pathGlobs: upsert.pathGlobs.isEmpty ? ["**/*"] : upsert.pathGlobs,
            payload: upsert.payload,
            examples: upsert.examples ?? [],
            body: upsert.body ?? "",
            createdAt: now,
            updatedAt: now
        )
        try await req.application.gegenlesenStore.insertRule(rule)
        await embedRule(rule, on: req)
        return try encoded(RuleDTO(rule: rule), status: .created, on: req)
    }

    static func update(_ req: Request) async throws -> RuleDTO {
        var existing = try await requireRule(req)
        let upsert = try decodeUpsert(req)
        existing.title = upsert.title
        existing.severity = upsert.severity
        existing.kind = upsert.kind
        if let enabled = upsert.enabled {
            existing.enabled = enabled
        }
        existing.languages = upsert.languages
        existing.pathGlobs = upsert.pathGlobs.isEmpty ? ["**/*"] : upsert.pathGlobs
        existing.payload = upsert.payload
        if let examples = upsert.examples {
            existing.examples = examples
        }
        if let body = upsert.body {
            existing.body = body
        }
        existing.updatedAt = Date()
        try await req.application.gegenlesenStore.updateRule(existing)
        await embedRule(existing, on: req)
        return RuleDTO(rule: existing)
    }

    static func remove(_ req: Request) async throws -> RuleDTO {
        let existing = try await requireRule(req)
        guard let deleted = try await req.application.gegenlesenStore.softDeleteRule(id: existing.id) else {
            throw APIError.notFound()
        }
        await embedRule(deleted, on: req)
        return RuleDTO(rule: deleted)
    }

    static func promote(_ req: Request) async throws -> Response {
        let existing = try await requireRule(req)
        if existing.provenance == .handwritten {
            throw APIError.conflict("rule is already handwritten")
        }
        if try await req.application.gegenlesenStore.rulePromotedFrom(existing.id) != nil {
            throw APIError.conflict("rule already promoted")
        }
        let now = Date()
        let newID = try await uniqueID(base: RuleID(existing.id.rawValue + "-handwritten"), store: req.application.gegenlesenStore)
        let copy = Rule(
            id: newID,
            title: existing.title,
            severity: existing.severity,
            kind: existing.kind,
            enabled: true,
            provenance: .handwritten,
            languages: existing.languages,
            pathGlobs: existing.pathGlobs,
            payload: existing.payload,
            examples: existing.examples,
            sourcePRRefs: existing.sourcePRRefs,
            promotedFromRuleID: existing.id,
            body: existing.body,
            createdAt: now,
            updatedAt: now
        )
        try await req.application.gegenlesenStore.insertRule(copy)
        await embedRule(copy, on: req)
        return try encoded(RuleDTO(rule: copy), status: .created, on: req)
    }

    static func enable(_ req: Request) async throws -> RuleDTO {
        try await setEnabled(req, true)
    }

    static func disable(_ req: Request) async throws -> RuleDTO {
        try await setEnabled(req, false)
    }

    private static func setEnabled(_ req: Request, _ enabled: Bool) async throws -> RuleDTO {
        let existing = try await requireRule(req)
        guard let updated = try await req.application.gegenlesenStore.setRuleEnabled(id: existing.id, enabled: enabled) else {
            throw APIError.notFound()
        }
        await embedRule(updated, on: req)
        return RuleDTO(rule: updated)
    }

    private static func embedRule(_ rule: Rule, on req: Request) async {
        try? await ArchitectureIndexJob(
            store: req.application.gegenlesenStore,
            embedder: req.application.gegenlesenEmbedder
        ).embedRule(rule)
    }

    private static func requireRule(_ req: Request) async throws -> Rule {
        guard let raw = req.parameters.get("id") else {
            throw APIError.notFound()
        }
        guard let rule = try await req.application.gegenlesenStore.rule(id: RuleID(raw)) else {
            throw APIError.notFound()
        }
        return rule
    }

    private static func parseFilter(_ req: Request) throws -> RuleListFilter {
        var filter = RuleListFilter()
        if let raw = req.query[String.self, at: "enabled"] {
            filter.enabled = try parseBool(raw, name: "enabled")
        }
        if let raw = req.query[String.self, at: "kind"] {
            guard let kind = RuleKind(rawValue: raw) else {
                throw APIError.badRequest("invalid kind")
            }
            filter.kind = kind
        }
        if let raw = req.query[String.self, at: "provenance"] {
            guard let provenance = RuleProvenance(rawValue: raw) else {
                throw APIError.badRequest("invalid provenance")
            }
            filter.provenance = provenance
        }
        return filter
    }

    private static func parseBool(_ raw: String, name: String) throws -> Bool {
        switch raw.lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: throw APIError.badRequest("invalid \(name)")
        }
    }

    private static func decodeUpsert(_ req: Request) throws -> RuleUpsert {
        do {
            return try req.content.decode(RuleUpsert.self)
        } catch {
            throw APIError.badRequest("invalid rule payload")
        }
    }

    private static func uniqueID(base: RuleID, store: Store) async throws -> RuleID {
        var candidate = base.isValid ? base : RuleID("rule-copy")
        var suffix = 2
        while try await store.rule(id: candidate) != nil {
            let raw = String(base.rawValue.prefix(120)) + "-\(suffix)"
            candidate = RuleID(raw)
            suffix += 1
            if suffix > 10_000 {
                throw APIError.conflict("could not allocate rule id")
            }
        }
        return candidate
    }

    private static func encoded<T: Content>(_ body: T, status: HTTPResponseStatus, on req: Request) throws -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .json
        let data = try JSONCoding.encoder.encode(body)
        return Response(status: status, headers: headers, body: .init(data: data))
    }
}