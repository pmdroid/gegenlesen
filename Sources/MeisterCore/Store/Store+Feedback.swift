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

    public func deleteFeedback(id: Int) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM finding_feedback WHERE id = ?", arguments: [id])
        }
    }

    public func recordFindingFeedback(
        finding: Finding,
        verdict: FeedbackVerdict,
        reaction: FeedbackReaction?,
        comment: String?,
        now: Date = Date()
    ) throws -> FindingFeedback {
        try write { db in
            var suggestedRuleID: RuleID?
            if verdict == .shouldBeRule {
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
            return FindingFeedback(row: row)
        }
    }
}

private func insertSuggestedRule(
    from finding: Finding,
    comment: String?,
    now: Date,
    db: Database
) throws -> RuleID {
    let base = RuleID.slug(from: finding.title)
    let id = try allocateRuleID(base, db: db)
    var parts = [finding.title, finding.message]
    if let comment {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }
    }
    let language = finding.filePath.map(LanguageMap.language(forPath:))
    let languages = language.map { [$0.rawValue] } ?? []
    let pathGlobs = [LanguageMap.pathGlob(for: language ?? .other)]
    let rule = Rule(
        id: id,
        title: finding.title,
        severity: finding.severity,
        kind: .semantic,
        enabled: false,
        provenance: .suggested,
        languages: languages,
        pathGlobs: pathGlobs,
        payload: .semantic(instruction: parts.joined(separator: "\n\n"), fewShots: []),
        body: comment ?? "",
        createdAt: now,
        updatedAt: now
    )
    try insertRuleRow(rule, db: db)
    try refreshRuleFTS(id: rule.id, db: db)
    return id
}

private func allocateRuleID(_ base: RuleID, db: Database) throws -> RuleID {
    var candidate = base.isValid ? base : RuleID("suggested-rule")
    var suffix = 2
    while try Row.fetchOne(db, sql: "SELECT id FROM rules WHERE id = ?", arguments: [candidate.rawValue]) != nil {
        candidate = RuleID(String(base.rawValue.prefix(120)) + "-\(suffix)")
        suffix += 1
        if suffix > 10_000 {
            throw StoreJobError.notFound
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
