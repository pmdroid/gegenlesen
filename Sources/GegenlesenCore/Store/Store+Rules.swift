import Foundation
import GRDB

public struct RuleListFilter: Sendable {
    public var enabled: Bool?
    public var kind: RuleKind?
    public var provenance: RuleProvenance?
    public var includeDeleted: Bool
    public var repository: String?
    public var unscoped: Bool
    public var includeGlobal: Bool

    public init(
        enabled: Bool? = nil,
        kind: RuleKind? = nil,
        provenance: RuleProvenance? = nil,
        includeDeleted: Bool = false,
        repository: String? = nil,
        unscoped: Bool = false,
        includeGlobal: Bool = false
    ) {
        self.enabled = enabled
        self.kind = kind
        self.provenance = provenance
        self.includeDeleted = includeDeleted
        self.repository = repository
        self.unscoped = unscoped
        self.includeGlobal = includeGlobal
    }

    public static func applicable(to repository: String?) -> RuleListFilter {
        if let repository {
            return RuleListFilter(repository: repository, includeGlobal: true)
        }
        return RuleListFilter(unscoped: true)
    }
}

extension Store {
    public func rule(id: RuleID, includeDeleted: Bool = true) throws -> Rule? {
        try read { db in
            let sql = includeDeleted
                ? "SELECT * FROM rules WHERE id = ?"
                : "SELECT * FROM rules WHERE id = ? AND deleted_at IS NULL"
            return try Row.fetchOne(db, sql: sql, arguments: [id.rawValue]).map(Rule.init(row:))
        }
    }

    public func listRules(_ filter: RuleListFilter = RuleListFilter()) throws -> [Rule] {
        try read { db in
            var clauses: [String] = []
            var arguments: [any DatabaseValueConvertible] = []
            if !filter.includeDeleted {
                clauses.append("deleted_at IS NULL")
            }
            if let enabled = filter.enabled {
                clauses.append("enabled = ?")
                arguments.append(enabled ? 1 : 0)
            }
            if let kind = filter.kind {
                clauses.append("kind = ?")
                arguments.append(kind.rawValue)
            }
            if let provenance = filter.provenance {
                clauses.append("provenance = ?")
                arguments.append(provenance.rawValue)
            }
            appendRepositoryFilter(
                clauses: &clauses,
                arguments: &arguments,
                repository: filter.repository,
                unscoped: filter.unscoped,
                includeGlobal: filter.includeGlobal
            )
            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM rules \(whereSQL) ORDER BY title, id",
                arguments: StatementArguments(arguments)
            )
            return rows.map(Rule.init(row:))
        }
    }

    public func insertRule(_ rule: Rule) throws {
        try write { db in
            try insertRuleRow(rule, db: db)
            try refreshRuleFTS(id: rule.id, db: db)
        }
    }

    public func insertRuleIfAbsent(_ rule: Rule) throws -> Bool {
        try write { db in
            if try Row.fetchOne(db, sql: "SELECT id FROM rules WHERE id = ?", arguments: [rule.id.rawValue]) != nil {
                return false
            }
            try insertRuleRow(rule, db: db)
            try refreshRuleFTS(id: rule.id, db: db)
            return true
        }
    }

    public func updateRule(_ rule: Rule) throws {
        try write { db in
            try updateRuleRow(rule, db: db)
        }
    }

    public func setRuleEnabled(id: RuleID, enabled: Bool, at now: Date = Date()) throws -> Rule? {
        guard var rule = try rule(id: id) else { return nil }
        rule.enabled = enabled
        rule.updatedAt = now
        try updateRule(rule)
        return rule
    }

    public func softDeleteRule(id: RuleID, at now: Date = Date()) throws -> Rule? {
        guard var rule = try rule(id: id) else { return nil }
        if rule.deletedAt == nil {
            rule.deletedAt = now
            rule.updatedAt = now
            try updateRule(rule)
        }
        return rule
    }

    public func appendSourcePRRefs(id: RuleID, refs: [String], at now: Date = Date()) throws -> Rule? {
        guard var rule = try rule(id: id) else { return nil }
        var seen = Set(rule.sourcePRRefs)
        var changed = false
        for ref in refs where !ref.isEmpty && !seen.contains(ref) {
            rule.sourcePRRefs.append(ref)
            seen.insert(ref)
            changed = true
        }
        if changed || rule.updatedAt != now {
            rule.updatedAt = now
            try updateRule(rule)
        }
        return rule
    }

    public func ftsBM25Scores(query: String) throws -> [RuleID: Double] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        return try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT rules.id AS id, bm25(rules_fts) AS score
                    FROM rules
                    JOIN rules_fts ON rules_fts.rowid = rules.rowid
                    WHERE rules_fts MATCH ?
                      AND rules.deleted_at IS NULL
                    """,
                arguments: [trimmed]
            )
            var scores: [RuleID: Double] = [:]
            for row in rows {
                guard let id = row["id"] as String? else { continue }
                let bm25 = (row["score"] as Double?) ?? 0
                scores[RuleID(id)] = -bm25
            }
            return scores
        }
    }

    public func ftsTop1Rule(matching title: String) throws -> Rule? {
        let phrase = ftsPhrase(title)
        guard !phrase.isEmpty else { return nil }
        // Restrict MATCH to the title column so body/instruction hits cannot absorb a new rule.
        let query = "title : \(phrase)"
        return try read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT rules.* FROM rules
                    JOIN rules_fts ON rules_fts.rowid = rules.rowid
                    WHERE rules_fts MATCH ?
                      AND rules.deleted_at IS NULL
                    ORDER BY rank
                    LIMIT 1
                    """,
                arguments: [query]
            )
            return row.map(Rule.init(row:))
        }
    }

    public func rulePromotedFrom(_ id: RuleID) throws -> Rule? {
        try read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM rules
                    WHERE promoted_from_rule_id = ?
                      AND deleted_at IS NULL
                    LIMIT 1
                    """,
                arguments: [id.rawValue]
            ).map(Rule.init(row:))
        }
    }

    public func insertFindings(_ drafts: [FindingDraft], jobID: JobID, now: Date = Date()) throws -> [Finding] {
        guard !drafts.isEmpty else { return [] }
        return try write { db in
            var findings: [Finding] = []
            findings.reserveCapacity(drafts.count)
            for draft in drafts {
                let finding = Finding(
                    id: FindingID.generate(at: now),
                    jobID: jobID,
                    ruleID: draft.ruleID,
                    phase: draft.phase,
                    reviewerSlot: nil,
                    severity: draft.severity,
                    title: draft.title,
                    message: draft.message,
                    filePath: draft.filePath,
                    startLine: draft.startLine,
                    endLine: draft.endLine,
                    snippet: draft.snippet,
                    agentRationale: draft.rationale,
                    judgeVerdict: draft.requiresJudge ? nil : .keep,
                    confidence: draft.confidence,
                    lifecycle: .new,
                    suggestedPatch: draft.suggestedPatch,
                    evidenceOK: draft.requiresJudge ? draft.evidenceOK : true,
                    createdAt: now
                )
                try db.execute(
                    sql: """
                        INSERT INTO findings (
                          id, job_id, rule_id, phase, reviewer_slot, severity,
                          title, message, file_path, start_line, end_line, snippet,
                          agent_rationale, judge_verdict, confidence, lifecycle,
                          suggested_patch, evidence_ok, created_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        finding.id.rawValue,
                        finding.jobID.rawValue,
                        finding.ruleID?.rawValue,
                        finding.phase.rawValue,
                        finding.reviewerSlot?.rawValue,
                        finding.severity.rawValue,
                        finding.title,
                        finding.message,
                        finding.filePath,
                        finding.startLine,
                        finding.endLine,
                        finding.snippet,
                        finding.agentRationale,
                        finding.judgeVerdict?.rawValue,
                        finding.confidence,
                        finding.lifecycle.rawValue,
                        finding.suggestedPatch,
                        finding.evidenceOK.map { $0 ? 1 : 0 },
                        ISO8601Dates.string(from: finding.createdAt),
                    ]
                )
                findings.append(finding)
            }
            return findings
        }
    }

}

func updateRuleRow(_ rule: Rule, db: Database) throws {
    try db.execute(
        sql: """
            UPDATE rules SET
              title = ?, severity = ?, kind = ?, enabled = ?, deleted_at = ?,
              provenance = ?, languages_json = ?, path_globs_json = ?,
              repository = ?, payload_json = ?, examples_json = ?, source_pr_refs_json = ?,
              promoted_from_rule_id = ?, body_md = ?, updated_at = ?
            WHERE id = ?
            """,
        arguments: [
            rule.title,
            rule.severity.rawValue,
            rule.kind.rawValue,
            rule.enabled ? 1 : 0,
            rule.deletedAt.map(ISO8601Dates.string(from:)),
            rule.provenance.rawValue,
            encodeJSON(rule.languages),
            encodeJSON(rule.pathGlobs),
            rule.repository,
            encodeJSON(rule.payload),
            encodeJSON(rule.examples),
            encodeJSON(rule.sourcePRRefs),
            rule.promotedFromRuleID?.rawValue,
            rule.body,
            ISO8601Dates.string(from: rule.updatedAt),
            rule.id.rawValue,
        ]
    )
    try refreshRuleFTS(id: rule.id, db: db)
}

func insertRuleRow(_ rule: Rule, db: Database) throws {
    try db.execute(
        sql: """
            INSERT INTO rules (
              id, title, severity, kind, enabled, deleted_at, provenance,
              languages_json, path_globs_json, repository, payload_json, examples_json,
              source_pr_refs_json, promoted_from_rule_id, body_md, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
        arguments: [
            rule.id.rawValue,
            rule.title,
            rule.severity.rawValue,
            rule.kind.rawValue,
            rule.enabled ? 1 : 0,
            rule.deletedAt.map(ISO8601Dates.string(from:)),
            rule.provenance.rawValue,
            encodeJSON(rule.languages),
            encodeJSON(rule.pathGlobs),
            rule.repository,
            encodeJSON(rule.payload),
            encodeJSON(rule.examples),
            encodeJSON(rule.sourcePRRefs),
            rule.promotedFromRuleID?.rawValue,
            rule.body,
            ISO8601Dates.string(from: rule.createdAt),
            ISO8601Dates.string(from: rule.updatedAt),
        ]
    )
}

func refreshRuleFTS(id: RuleID, db: Database) throws {
    guard let rowid = try Int.fetchOne(
        db,
        sql: "SELECT rowid FROM rules WHERE id = ?",
        arguments: [id.rawValue]
    ) else { return }
    try? db.execute(
        sql: """
            INSERT INTO rules_fts(rules_fts, rowid, title, body_md, examples, payload)
            VALUES('delete', ?, '', '', '', '')
            """,
        arguments: [rowid]
    )
    try db.execute(
        sql: """
            INSERT INTO rules_fts(rowid, title, body_md, examples, payload)
            SELECT rowid, title, body_md, examples_json, payload_json
            FROM rules WHERE id = ?
            """,
        arguments: [id.rawValue]
    )
}

extension Rule {
    init(row: Row) {
        let languages = decodeJSON([String].self, row.optionalString("languages_json")) ?? []
        let globs = decodeJSON([String].self, row.optionalString("path_globs_json")) ?? []
        let payload = decodeJSON(RulePayload.self, row.optionalString("payload_json"))
            ?? .semantic(instruction: "", fewShots: [])
        let examples = decodeJSON([RuleExample].self, row.optionalString("examples_json")) ?? []
        let refs = decodeJSON([String].self, row.optionalString("source_pr_refs_json")) ?? []
        let enabled: Bool
        if let raw = row["enabled"] as Int? {
            enabled = raw != 0
        } else if let raw = row["enabled"] as Bool? {
            enabled = raw
        } else {
            enabled = true
        }
        self.init(
            id: RuleID(row.string("id")),
            title: row.string("title"),
            severity: Severity(rawValue: row.string("severity")) ?? .info,
            kind: RuleKind(rawValue: row.string("kind")) ?? .semantic,
            enabled: enabled,
            deletedAt: row.optionalString("deleted_at").flatMap(ISO8601Dates.date(from:)),
            provenance: RuleProvenance(rawValue: row.optionalString("provenance") ?? "") ?? .handwritten,
            languages: languages,
            pathGlobs: globs,
            repository: row.optionalString("repository"),
            payload: payload,
            examples: examples,
            sourcePRRefs: refs,
            promotedFromRuleID: row.optionalString("promoted_from_rule_id").map { RuleID($0) },
            body: row.optionalString("body_md") ?? "",
            createdAt: ISO8601Dates.date(from: row.string("created_at")) ?? Date(),
            updatedAt: ISO8601Dates.date(from: row.string("updated_at")) ?? Date()
        )
    }
}

private let ruleJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

private func ftsPhrase(_ title: String) -> String {
    let cleaned = title.replacingOccurrences(of: "\"", with: " ")
    let normalized = Normalize.whitespace(cleaned)
    guard !normalized.isEmpty else { return "" }
    return "\"" + normalized + "\""
}

private func encodeJSON<T: Encodable>(_ value: T) -> String {
    guard let data = try? ruleJSONEncoder.encode(value),
          let text = String(data: data, encoding: .utf8)
    else { return "null" }
    return text
}

private func decodeJSON<T: Decodable>(_ type: T.Type, _ raw: String?) -> T? {
    guard let raw, let data = raw.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

extension Row {
    fileprivate func string(_ column: String) -> String {
        self[column] as String? ?? ""
    }

    fileprivate func optionalString(_ column: String) -> String? {
        self[column] as String?
    }
}