import Foundation
import GRDB

extension Store {
    public func finding(id: FindingID) throws -> Finding? {
        try read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM findings WHERE id = ?", arguments: [id.rawValue])
                .map(Finding.init(row:))
        }
    }

    public func feedback(jobID: JobID) throws -> [FindingFeedback] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM finding_feedback WHERE job_id = ? ORDER BY id",
                arguments: [jobID.rawValue]
            ).map(FindingFeedback.init(row:))
        }
    }

    public func feedback(findingID: FindingID) throws -> [FindingFeedback] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM finding_feedback WHERE finding_id = ? ORDER BY id",
                arguments: [findingID.rawValue]
            ).map(FindingFeedback.init(row:))
        }
    }

    public func findingsAndFeedback() throws -> (findings: [Finding], feedback: [FindingFeedback]) {
        try read { db in
            let findings = try Row.fetchAll(db, sql: "SELECT * FROM findings")
                .map(Finding.init(row:))
            let feedback = try Row.fetchAll(
                db,
                sql: "SELECT * FROM finding_feedback ORDER BY id"
            ).map(FindingFeedback.init(row:))
            return (findings, feedback)
        }
    }

    public func applyFindingFeedback(
        finding: Finding,
        verdict: FeedbackVerdict,
        reaction: FeedbackReaction?,
        comment: String?,
        now: Date = Date()
    ) throws -> FeedbackWriteResult {
        try write { db in
            let existing = try Row.fetchAll(
                db,
                sql: "SELECT * FROM finding_feedback WHERE finding_id = ? ORDER BY id",
                arguments: [finding.id.rawValue]
            ).map(FindingFeedback.init(row:))

            if let reaction,
               let current = existing.reversed().first(where: { $0.verdict == .agree || $0.verdict == .disagree }),
               current.reaction == reaction {
                try db.execute(sql: "DELETE FROM finding_feedback WHERE id = ?", arguments: [current.id])
                return .cleared
            }

            if verdict == .agree || verdict == .disagree {
                for old in existing where old.verdict == .agree || old.verdict == .disagree {
                    try db.execute(sql: "DELETE FROM finding_feedback WHERE id = ?", arguments: [old.id])
                }
            }

            var suggestedRuleID: RuleID?
            if verdict == .shouldBeRule {
                if let current = existing.reversed().first(where: { $0.verdict.isCurrentVerdict }),
                   current.verdict == .shouldBeRule,
                   let existingID = current.suggestedRuleID {
                    if let comment {
                        try updateSuggestedRule(
                            id: existingID,
                            finding: finding,
                            comment: comment,
                            now: now,
                            db: db
                        )
                    }
                    return .reused(current)
                }
                suggestedRuleID = try insertSuggestedRule(from: finding, comment: comment, now: now, db: db)
            }

            try db.execute(
                sql: """
                    INSERT INTO finding_feedback (
                      finding_id, job_id, ts, verdict, reaction, comment, suggested_rule_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    finding.id.rawValue,
                    finding.jobID.rawValue,
                    ISO8601Dates.string(from: now),
                    verdict.rawValue,
                    reaction?.rawValue,
                    comment,
                    suggestedRuleID?.rawValue,
                ]
            )
            let rowID = db.lastInsertedRowID
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM finding_feedback WHERE id = ?",
                arguments: [rowID]
            ) else {
                throw StoreJobError.notFound
            }
            return .created(FindingFeedback(row: row))
        }
    }

    public func suppressedFingerprints(repository: String) throws -> Set<String> {
        guard let repo = RepositoryName.normalize(repository) else { return [] }
        return try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT f.fingerprint, f.rule_id, f.file_path, f.snippet
                    FROM findings f
                    JOIN jobs j ON j.id = f.job_id
                    JOIN finding_feedback latest ON latest.id = (
                      SELECT ff.id FROM finding_feedback ff
                      WHERE ff.finding_id = f.id
                        AND ff.verdict IN ('agree', 'disagree', 'should_be_rule')
                      ORDER BY ff.id DESC
                      LIMIT 1
                    )
                    WHERE latest.verdict = 'disagree'
                      AND j.repository = ?
                    """,
                arguments: [repo]
            )
            var fingerprints = Set<String>()
            for row in rows {
                let stored = row.optionalString("fingerprint")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let stored, !stored.isEmpty {
                    fingerprints.insert(stored)
                    continue
                }
                let ruleID = row.optionalString("rule_id").map { RuleID($0) }
                fingerprints.insert(
                    Fingerprint.sha256(
                        ruleID: ruleID,
                        path: row.optionalString("file_path") ?? "",
                        snippet: row.optionalString("snippet") ?? ""
                    )
                )
            }
            return fingerprints
        }
    }
}

public enum FeedbackWriteResult: Sendable, Equatable {
    case created(FindingFeedback)
    case reused(FindingFeedback)
    case cleared
}

private func insertSuggestedRule(
    from finding: Finding,
    comment: String?,
    now: Date,
    db: Database
) throws -> RuleID {
    let base = RuleID.slug(from: finding.title)
    let id = try allocateRuleID(base, db: db)
    let language = finding.filePath.flatMap { path -> Language? in
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : LanguageMap.language(forPath: trimmed)
    }
    let languages = language.map { [$0.rawValue] } ?? ["*"]
    let pathGlobs = [LanguageMap.pathGlob(for: language ?? .other)]
    let drafted = suggestedKindAndPayload(finding: finding, comment: comment)
    let rule = Rule(
        id: id,
        title: finding.title,
        severity: finding.severity,
        kind: drafted.kind,
        enabled: false,
        provenance: .suggested,
        languages: languages,
        pathGlobs: pathGlobs,
        payload: drafted.payload,
        body: comment ?? "",
        createdAt: now,
        updatedAt: now
    )
    try insertRuleRow(rule, db: db)
    try refreshRuleFTS(id: rule.id, db: db)
    return id
}

private func updateSuggestedRule(
    id: RuleID,
    finding: Finding,
    comment: String,
    now: Date,
    db: Database
) throws {
    guard var rule = try Row.fetchOne(
        db,
        sql: "SELECT * FROM rules WHERE id = ?",
        arguments: [id.rawValue]
    ).map(Rule.init(row:)) else { return }
    let drafted = suggestedKindAndPayload(finding: finding, comment: comment)
    rule.kind = drafted.kind
    rule.payload = drafted.payload
    rule.body = comment
    rule.updatedAt = now
    try updateRuleRow(rule, db: db)
}

private func suggestedKindAndPayload(finding: Finding, comment: String?) -> (kind: RuleKind, payload: RulePayload) {
    if let literal = oneLineSnippet(finding.snippet) {
        return (
            .deterministic,
            .regex(
                pattern: NSRegularExpression.escapedPattern(for: literal),
                flags: nil,
                message: finding.message
            )
        )
    }
    var parts = [finding.title, finding.message]
    if let comment {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }
    }
    return (.semantic, .semantic(instruction: parts.joined(separator: "\n\n"), fewShots: []))
}

private func oneLineSnippet(_ snippet: String?) -> String? {
    guard let snippet else { return nil }
    let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return nil }
    return trimmed
}

private func allocateRuleID(_ base: RuleID, db: Database) throws -> RuleID {
    let root = base.isValid ? base : RuleID("suggested-rule")
    var candidate = root
    var suffix = 2
    while try Row.fetchOne(db, sql: "SELECT id FROM rules WHERE id = ?", arguments: [candidate.rawValue]) != nil {
        candidate = RuleID(String(root.rawValue.prefix(120)) + "-\(suffix)")
        suffix += 1
        if suffix > 10_000 {
            candidate = RuleID("suggested-\(UUID().uuidString.lowercased().prefix(8))")
            break
        }
    }
    return candidate
}

extension FindingFeedback {
    fileprivate init(row: Row) {
        self.init(
            id: row["id"],
            findingID: FindingID(row.string("finding_id")),
            jobID: JobID(row.string("job_id")),
            ts: ISO8601Dates.date(from: row.string("ts")) ?? Date(),
            verdict: FeedbackVerdict(rawValue: row.string("verdict")) ?? .comment,
            reaction: row.optionalString("reaction").flatMap(FeedbackReaction.init(rawValue:)),
            comment: row.optionalString("comment"),
            suggestedRuleID: row.optionalString("suggested_rule_id").map { RuleID($0) }
        )
    }
}

extension Row {
    fileprivate func string(_ column: String) -> String {
        self[column] as String? ?? ""
    }

    fileprivate func optionalString(_ column: String) -> String? {
        self[column] as String?
    }
}
