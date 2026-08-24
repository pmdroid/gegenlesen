import Foundation
import GRDB

public struct ParentJobState: Sendable, Equatable {
    public var exists: Bool
    public var succeeded: Bool
    public var hasSHAs: Bool
    public var hasFiles: Bool

    public var isAcceptable: Bool {
        exists && succeeded && hasSHAs && hasFiles
    }
}

public struct JobListPage: Sendable {
    public var jobs: [Job]
    public var total: Int
}

extension Store {
    public func insertJob(_ job: Job) throws {
        try write { db in
            try db.execute(
                sql: """
                    INSERT INTO jobs (
                      id, created_at, updated_at, started_at, finished_at,
                      status, scope, parent_job_id, title, repository,
                      reviewer_a_model_id, reviewer_b_model_id, judge_model_id,
                      base_sha, head_sha, default_branch, archive_sha256,
                      archive_bytes, file_count, error_message,
                      container_name, container_name_a, container_name_b, timings_json,
                      risk_verdict, risk_json
                    ) VALUES (
                      ?, ?, ?, ?, ?,
                      ?, ?, ?, ?, ?,
                      ?, ?, ?,
                      ?, ?, ?, ?,
                      ?, ?, ?,
                      ?, ?, ?, ?,
                      ?, ?
                    )
                    """,
                arguments: job.sqlArguments
            )
        }
    }

    public func updateJobRisk(jobID: JobID, assessment: RiskAssessment) throws {
        try write { db in
            try db.execute(
                sql: """
                    UPDATE jobs
                    SET risk_verdict = ?, risk_json = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    assessment.verdict.rawValue,
                    RiskGate.encode(assessment),
                    ISO8601Dates.string(from: Date()),
                    jobID.rawValue,
                ]
            )
        }
    }

    public func updateJobTimings(jobID: JobID, timings: JobTimings) throws {
        let data = try JSONEncoder().encode(timings)
        guard let encoded = String(data: data, encoding: .utf8) else { return }
        try write { db in
            try db.execute(
                sql: """
                    UPDATE jobs
                    SET timings_json = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    encoded,
                    ISO8601Dates.string(from: Date()),
                    jobID.rawValue,
                ]
            )
        }
    }

    public func job(id: JobID) throws -> Job? {
        try read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM jobs WHERE id = ?", arguments: [id.rawValue])
                .map(Job.init(row:))
        }
    }

    public func listJobs(
        limit: Int,
        offset: Int,
        status: JobStatus? = nil,
        active: Bool = false,
        repository: String? = nil,
        unscoped: Bool = false,
        query: String? = nil
    ) throws -> JobListPage {
        try read { db in
            var clauses: [String] = []
            var arguments: [any DatabaseValueConvertible] = []
            if let status {
                clauses.append("status = ?")
                arguments.append(status.rawValue)
            } else if active {
                clauses.append("status NOT IN ('succeeded', 'failed', 'cancelled')")
            }
            if unscoped {
                clauses.append("repository IS NULL")
            } else if let repository {
                clauses.append("repository = ?")
                arguments.append(repository)
            }
            if let query, !query.isEmpty {
                clauses.append("IFNULL(title, id) LIKE ? ESCAPE '\\'")
                arguments.append(likePattern(query))
            }
            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM jobs \(whereSQL)",
                arguments: StatementArguments(arguments)
            ) ?? 0
            var pageArguments = arguments
            pageArguments.append(limit)
            pageArguments.append(offset)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM jobs
                    \(whereSQL)
                    ORDER BY created_at DESC
                    LIMIT ? OFFSET ?
                    """,
                arguments: StatementArguments(pageArguments)
            )
            return JobListPage(jobs: rows.map(Job.init(row:)), total: total)
        }
    }

    public func updateJobRepository(id: JobID, repository: String?, at now: Date = Date()) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE jobs SET repository = ?, updated_at = ? WHERE id = ?",
                arguments: [repository, ISO8601Dates.string(from: now), id.rawValue]
            )
        }
    }

    public func listRepositories() throws -> [String] {
        try read { db in
            let rows = try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT repository FROM (
                      SELECT repository FROM jobs WHERE repository IS NOT NULL
                      UNION
                      SELECT repository FROM rules
                        WHERE repository IS NOT NULL AND deleted_at IS NULL
                      UNION
                      SELECT repository FROM context_notes
                        WHERE repository IS NOT NULL AND deleted_at IS NULL
                    )
                    ORDER BY repository
                    """
            )
            return rows
        }
    }

    public func queuePosition(createdAt: Date) throws -> Int {
        let stamp = ISO8601Dates.string(from: createdAt)
        return try read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM jobs
                    WHERE status = 'queued' AND created_at <= ?
                    """,
                arguments: [stamp]
            ) ?? 1
        }
    }

    public func queuePosition(for job: Job) throws -> Int? {
        guard job.status == .queued else { return nil }
        return try queuePosition(createdAt: job.createdAt)
    }

    public func activeArchiveBytes() throws -> Int {
        try read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(archive_bytes), 0) FROM jobs
                    WHERE status NOT IN ('succeeded', 'failed', 'cancelled')
                    """
            ) ?? 0
        }
    }

    public func parentState(id: JobID) throws -> ParentJobState {
        try read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT status, base_sha, head_sha FROM jobs WHERE id = ?",
                arguments: [id.rawValue]
            ) else {
                return ParentJobState(exists: false, succeeded: false, hasSHAs: false, hasFiles: false)
            }
            let status = (row["status"] as String?) == JobStatus.succeeded.rawValue
            let base = row["base_sha"] as String?
            let head = row["head_sha"] as String?
            let hasSHAs = firstNonEmpty(base) != nil && firstNonEmpty(head) != nil
            let files = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM job_files WHERE job_id = ?",
                arguments: [id.rawValue]
            ) ?? 0
            return ParentJobState(
                exists: true,
                succeeded: status,
                hasSHAs: hasSHAs,
                hasFiles: files > 0
            )
        }
    }

    public func replaceJobFiles(_ files: [JobFile]) throws {
        guard let jobID = files.first?.jobID else { return }
        try write { db in
            try db.execute(sql: "DELETE FROM job_files WHERE job_id = ?", arguments: [jobID.rawValue])
            for file in files {
                try db.execute(
                    sql: """
                        INSERT INTO job_files (
                          job_id, path, sha256, status, old_path, language, bytes
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        file.jobID.rawValue,
                        file.path,
                        file.sha256,
                        file.status.rawValue,
                        file.oldPath,
                        file.language?.rawValue,
                        file.bytes,
                    ]
                )
            }
        }
    }

    public func jobFiles(id: JobID) throws -> [JobFile] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM job_files WHERE job_id = ? ORDER BY path",
                arguments: [id.rawValue]
            ).map { row in
                JobFile(
                    jobID: JobID(row.string("job_id")),
                    path: row.string("path"),
                    sha256: row.optionalString("sha256"),
                    status: FileChangeStatus(rawValue: row.string("status")) ?? .modified,
                    oldPath: row.optionalString("old_path"),
                    language: row.optionalString("language").flatMap(Language.init(rawValue:)),
                    bytes: row["bytes"]
                )
            }
        }
    }

    public func appendEvent(
        jobID: JobID,
        level: EventLevel,
        message: String,
        payloadJSON: String? = nil,
        at ts: Date = Date()
    ) throws {
        try write { db in
            try db.execute(
                sql: """
                    INSERT INTO job_events (job_id, ts, level, message, payload_json)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    jobID.rawValue,
                    ISO8601Dates.string(from: ts),
                    level.rawValue,
                    message,
                    payloadJSON,
                ]
            )
        }
    }

    public func events(jobID: JobID) throws -> [JobEvent] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM job_events WHERE job_id = ? ORDER BY id",
                arguments: [jobID.rawValue]
            ).map { row in
                JobEvent(
                    id: row["id"],
                    jobID: JobID(row.string("job_id")),
                    ts: ISO8601Dates.date(from: row.string("ts")) ?? Date(),
                    level: EventLevel(rawValue: row.string("level")) ?? .info,
                    message: row.string("message"),
                    payloadJSON: row.optionalString("payload_json")
                )
            }
        }
    }

    public func findingFeedback(jobID: JobID) throws -> [[String: String]] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT finding_id, ts, verdict, reaction, comment
                    FROM finding_feedback
                    WHERE job_id = ?
                    ORDER BY id
                    """,
                arguments: [jobID.rawValue]
            ).map { row in
                var object: [String: String] = [
                    "finding_id": row["finding_id"] as String? ?? "",
                    "ts": row["ts"] as String? ?? "",
                    "verdict": row["verdict"] as String? ?? "",
                ]
                if let reaction = row["reaction"] as String? { object["reaction"] = reaction }
                if let comment = row["comment"] as String? { object["comment"] = comment }
                return object
            }
        }
    }

    public func findings(jobID: JobID) throws -> [Finding] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM findings WHERE job_id = ? ORDER BY created_at, id",
                arguments: [jobID.rawValue]
            ).map(Finding.init(row:))
        }
    }

    public func summary(jobID: JobID) throws -> JobSummary {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT lifecycle, judge_verdict FROM findings WHERE job_id = ?",
                arguments: [jobID.rawValue]
            )
            var summary = JobSummary.zero
            for row in rows {
                switch FindingLifecycle(rawValue: row["lifecycle"] ?? "") {
                case .new: summary.new += 1
                case .stillOpen: summary.stillOpen += 1
                case .resolved: summary.resolved += 1
                case .relocated: summary.relocated += 1
                case .none: break
                }
                if (row["judge_verdict"] as String?) == JudgeVerdict.drop.rawValue {
                    summary.dropped += 1
                }
            }
            return summary
        }
    }

    public func apply(
        jobID: JobID,
        event: JobStateMachine.Event,
        errorMessage: String? = nil,
        baseSHA: String? = nil,
        headSHA: String? = nil,
        fileCount: Int? = nil,
        now: Date = Date()
    ) throws -> Job {
        try write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM jobs WHERE id = ?",
                arguments: [jobID.rawValue]
            ) else {
                throw StoreJobError.notFound
            }
            var job = Job(row: row)
            if job.status.isTerminal {
                return job
            }
            let next = try JobStateMachine.transition(from: job.status, event)
            job.status = next
            job.updatedAt = now
            if event == .dequeued {
                job.startedAt = job.startedAt ?? now
            }
            if next.isTerminal {
                job.finishedAt = now
            }
            if let errorMessage {
                job.errorMessage = errorMessage
            } else if case .unpackFailed(let message) = event {
                job.errorMessage = message
            } else if case .identifyFailed(let message) = event {
                job.errorMessage = message
            } else if case .rulesFailed(let message) = event {
                job.errorMessage = message
            } else if case .reviewFailed(let message) = event {
                job.errorMessage = message
            } else if event == .processRestarted {
                job.errorMessage = "process_restarted"
            } else if event == .deterministicTimeout {
                job.errorMessage = "deterministic_timeout"
            }
            if let baseSHA {
                job.baseSHA = baseSHA
            }
            if let headSHA {
                job.headSHA = headSHA
            }
            if let fileCount {
                job.fileCount = fileCount
            }
            try db.execute(
                sql: """
                    UPDATE jobs SET
                      updated_at = ?, started_at = ?, finished_at = ?,
                      status = ?, error_message = ?,
                      base_sha = ?, head_sha = ?, file_count = ?
                    WHERE id = ?
                    """,
                arguments: [
                    ISO8601Dates.string(from: job.updatedAt),
                    job.startedAt.map(ISO8601Dates.string(from:)),
                    job.finishedAt.map(ISO8601Dates.string(from:)),
                    job.status.rawValue,
                    job.errorMessage,
                    job.baseSHA,
                    job.headSHA,
                    job.fileCount,
                    job.id.rawValue,
                ]
            )
            return job
        }
    }

    public func finishJob(
        id: JobID,
        status: JobStatus,
        errorMessage: String? = nil,
        now: Date = Date()
    ) throws -> Job? {
        try write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM jobs WHERE id = ?",
                arguments: [id.rawValue]
            ) else {
                return nil
            }
            var job = Job(row: row)
            if job.status.isTerminal {
                return job
            }
            job.status = status
            job.updatedAt = now
            job.finishedAt = now
            if job.startedAt == nil {
                job.startedAt = now
            }
            if let errorMessage {
                job.errorMessage = errorMessage
            }
            try db.execute(
                sql: """
                    UPDATE jobs SET
                      updated_at = ?, started_at = ?, finished_at = ?,
                      status = ?, error_message = ?
                    WHERE id = ?
                    """,
                arguments: [
                    ISO8601Dates.string(from: job.updatedAt),
                    job.startedAt.map(ISO8601Dates.string(from:)),
                    job.finishedAt.map(ISO8601Dates.string(from:)),
                    job.status.rawValue,
                    job.errorMessage,
                    job.id.rawValue,
                ]
            )
            return job
        }
    }

    public func updateJobContainers(
        jobID: JobID,
        containerName: String? = nil,
        containerNameA: String? = nil,
        containerNameB: String? = nil
    ) throws {
        try write { db in
            try db.execute(
                sql: """
                    UPDATE jobs SET
                      container_name = COALESCE(?, container_name),
                      container_name_a = COALESCE(?, container_name_a),
                      container_name_b = COALESCE(?, container_name_b),
                      updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    containerName,
                    containerNameA,
                    containerNameB,
                    ISO8601Dates.string(from: Date()),
                    jobID.rawValue,
                ]
            )
        }
    }

    public func updateFindings(_ findings: [Finding]) throws {
        guard !findings.isEmpty else { return }
        try write { db in
            for finding in findings {
                try db.execute(
                    sql: """
                        UPDATE findings SET
                          judge_verdict = ?,
                          judge_severity = ?,
                          judge_rationale = ?,
                          evidence_ok = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        finding.judgeVerdict?.rawValue,
                        finding.judgeSeverity?.rawValue,
                        finding.judgeRationale,
                        finding.evidenceOK.map { $0 ? 1 : 0 },
                        finding.id.rawValue,
                    ]
                )
            }
        }
    }

    public func insertParsedFindings(_ findings: [Finding]) throws {
        guard !findings.isEmpty else { return }
        try write { db in
            for finding in findings {
                try db.execute(
                    sql: """
                        INSERT INTO findings (
                          id, job_id, rule_id, phase, reviewer_slot, severity,
                          title, message, file_path, start_line, end_line, snippet,
                          agent_rationale, judge_verdict, judge_severity, judge_rationale,
                          confidence, lifecycle, parent_finding_id, suggested_patch,
                          fingerprint, evidence_ok, created_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        finding.judgeSeverity?.rawValue,
                        finding.judgeRationale,
                        finding.confidence,
                        finding.lifecycle.rawValue,
                        finding.parentFindingID?.rawValue,
                        finding.suggestedPatch,
                        finding.fingerprint,
                        finding.evidenceOK.map { $0 ? 1 : 0 },
                        ISO8601Dates.string(from: finding.createdAt),
                    ]
                )
            }
        }
    }

    public func failProcessRestarted() throws -> Int {
        let now = ISO8601Dates.string(from: Date())
        return try write { db in
            try db.execute(
                sql: """
                    UPDATE jobs
                    SET status = 'failed',
                        error_message = 'process_restarted',
                        finished_at = ?,
                        updated_at = ?
                    WHERE status NOT IN ('queued', 'succeeded', 'failed', 'cancelled')
                    """,
                arguments: [now, now]
            )
            let inFlight = db.changesCount
            try db.execute(
                sql: """
                    UPDATE jobs
                    SET status = 'failed',
                        error_message = 'process_restarted',
                        finished_at = ?,
                        updated_at = ?
                    WHERE status = 'queued' AND started_at IS NOT NULL
                    """,
                arguments: [now, now]
            )
            return inFlight + db.changesCount
        }
    }

    public func hasActiveJobs() throws -> Bool {
        try read { db in
            let count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM jobs
                    WHERE status NOT IN ('succeeded', 'failed', 'cancelled')
                    """
            ) ?? 0
            return count > 0
        }
    }

    public func learnedWithin(minutes: Int, now: Date) throws -> Bool {
        guard minutes > 0 else { return false }
        let cutoff = ISO8601Dates.string(from: now.addingTimeInterval(TimeInterval(-minutes * 60)))
        return try read { db in
            let count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM jobs
                    WHERE title LIKE 'learn %'
                      AND created_at >= ?
                    """,
                arguments: [cutoff]
            ) ?? 0
            return count > 0
        }
    }

    public func nextJobNeedingLearn() throws -> JobID? {
        try read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT j.id
                    FROM jobs j
                    WHERE j.status = 'succeeded'
                      AND (j.title IS NULL OR j.title NOT LIKE 'learn %')
                      AND (
                        EXISTS (
                          SELECT 1 FROM finding_feedback f WHERE f.job_id = j.id
                        )
                        OR json_extract(j.risk_json, '$.safe_unread') IS NOT NULL
                      )
                      AND NOT EXISTS (
                        SELECT 1 FROM jobs c
                        WHERE c.parent_job_id = j.id
                          AND c.title LIKE 'learn %'
                          AND c.status NOT IN ('succeeded', 'failed', 'cancelled')
                      )
                      AND (
                        SELECT MAX(activity.ts) FROM (
                          SELECT f.ts AS ts
                          FROM finding_feedback f
                          WHERE f.job_id = j.id
                          UNION ALL
                          SELECT j.updated_at AS ts
                          WHERE json_extract(j.risk_json, '$.safe_unread') IS NOT NULL
                        ) AS activity
                      ) > COALESCE(
                        (
                          SELECT MAX(c.finished_at)
                          FROM jobs c
                          WHERE c.parent_job_id = j.id
                            AND c.title LIKE 'learn %'
                            AND c.status IN ('succeeded', 'failed', 'cancelled')
                            AND c.finished_at IS NOT NULL
                        ),
                        '0000-01-01T00:00:00Z'
                      )
                    ORDER BY (
                      SELECT MAX(activity.ts) FROM (
                        SELECT f.ts AS ts
                        FROM finding_feedback f
                        WHERE f.job_id = j.id
                        UNION ALL
                        SELECT j.updated_at AS ts
                        WHERE json_extract(j.risk_json, '$.safe_unread') IS NOT NULL
                      ) AS activity
                    ) ASC
                    LIMIT 1
                    """
            ).map { JobID($0) }
        }
    }

    public func queuedUnstartedIDs() throws -> [JobID] {
        try read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM jobs
                    WHERE status = 'queued' AND started_at IS NULL
                    ORDER BY created_at
                    """
            ).map { JobID($0) }
        }
    }

    public func terminalJobs() throws -> [Job] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM jobs
                    WHERE status IN ('succeeded', 'failed', 'cancelled')
                    """
            ).map(Job.init(row:))
        }
    }
}

public enum StoreJobError: Error, Sendable, Equatable {
    case notFound
}

extension Job {
    fileprivate var sqlArguments: StatementArguments {
        StatementArguments([
            id.rawValue,
            ISO8601Dates.string(from: createdAt),
            ISO8601Dates.string(from: updatedAt),
            startedAt.map(ISO8601Dates.string(from:)),
            finishedAt.map(ISO8601Dates.string(from:)),
            status.rawValue,
            scope.rawValue,
            parentJobID?.rawValue,
            title,
            repository,
            reviewerAModelID,
            reviewerBModelID,
            judgeModelID,
            baseSHA,
            headSHA,
            defaultBranch,
            archiveSHA256,
            archiveBytes,
            fileCount,
            errorMessage,
            containerName,
            containerNameA,
            containerNameB,
            timings.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) },
            risk?.verdict.rawValue,
            risk.flatMap(RiskGate.encode),
        ])
    }

    fileprivate init(row: Row) {
        let timingsJSON = row.optionalString("timings_json")
        let timings = timingsJSON.flatMap { raw -> JobTimings? in
            raw.data(using: .utf8).flatMap { try? JSONDecoder().decode(JobTimings.self, from: $0) }
        }
        self.init(
            id: JobID(row.string("id")),
            createdAt: ISO8601Dates.date(from: row.string("created_at")) ?? Date(),
            updatedAt: ISO8601Dates.date(from: row.string("updated_at")) ?? Date(),
            startedAt: row.optionalString("started_at").flatMap(ISO8601Dates.date(from:)),
            finishedAt: row.optionalString("finished_at").flatMap(ISO8601Dates.date(from:)),
            status: JobStatus(rawValue: row.string("status")) ?? .queued,
            scope: JobScope(rawValue: row.string("scope")) ?? .full,
            parentJobID: row.optionalString("parent_job_id").map { JobID($0) },
            title: row.optionalString("title"),
            repository: row.optionalString("repository"),
            reviewerAModelID: row.string("reviewer_a_model_id"),
            reviewerBModelID: row.string("reviewer_b_model_id"),
            judgeModelID: row.string("judge_model_id"),
            baseSHA: row.optionalString("base_sha"),
            headSHA: row.optionalString("head_sha"),
            defaultBranch: row.optionalString("default_branch"),
            archiveSHA256: row.optionalString("archive_sha256"),
            archiveBytes: row["archive_bytes"],
            fileCount: row["file_count"],
            errorMessage: row.optionalString("error_message"),
            containerName: row.optionalString("container_name"),
            containerNameA: row.optionalString("container_name_a"),
            containerNameB: row.optionalString("container_name_b"),
            timings: timings,
            risk: RiskGate.decode(row.optionalString("risk_json"))
        )
    }
}

extension Finding {
    init(row: Row) {
        let evidence: Bool?
        if let raw = row["evidence_ok"] as Int? {
            evidence = raw != 0
        } else {
            evidence = nil
        }
        self.init(
            id: FindingID(row.string("id")),
            jobID: JobID(row.string("job_id")),
            ruleID: row.optionalString("rule_id").map { RuleID($0) },
            phase: FindingPhase(rawValue: row.string("phase")) ?? .deterministic,
            reviewerSlot: row.optionalString("reviewer_slot").flatMap(ReviewerSlot.init(rawValue:)),
            severity: Severity(rawValue: row.string("severity")) ?? .info,
            title: row.string("title"),
            message: row.string("message"),
            filePath: row.optionalString("file_path"),
            startLine: row["start_line"],
            endLine: row["end_line"],
            snippet: row.optionalString("snippet"),
            agentRationale: row.optionalString("agent_rationale"),
            judgeVerdict: row.optionalString("judge_verdict").flatMap(JudgeVerdict.init(rawValue:)),
            judgeSeverity: row.optionalString("judge_severity").flatMap(Severity.init(rawValue:)),
            judgeRationale: row.optionalString("judge_rationale"),
            confidence: row["confidence"],
            lifecycle: FindingLifecycle(rawValue: row.string("lifecycle")) ?? .new,
            parentFindingID: row.optionalString("parent_finding_id").map { FindingID($0) },
            suggestedPatch: row.optionalString("suggested_patch"),
            fingerprint: row.optionalString("fingerprint"),
            evidenceOK: evidence,
            createdAt: ISO8601Dates.date(from: row.string("created_at")) ?? Date()
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

private func firstNonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
