import Foundation
import GRDB

public struct ContextRetrieveHit: Sendable, Equatable {
    public var chunk: ContextChunk
    public var score: Float

    public init(chunk: ContextChunk, score: Float) {
        self.chunk = chunk
        self.score = score
    }
}

public struct MetricsSnapshot: Sendable, Equatable {
    public var queueDepth: Int
    public var jobsByStatusScope: [String: Int]
    public var findingsByKey: [String: Int]
    public var durationSeconds: [String: Double]
    public var dockerOOMTotal: Int
    public var archiveBytes: Int

    public init(
        queueDepth: Int,
        jobsByStatusScope: [String: Int],
        findingsByKey: [String: Int],
        durationSeconds: [String: Double],
        dockerOOMTotal: Int,
        archiveBytes: Int
    ) {
        self.queueDepth = queueDepth
        self.jobsByStatusScope = jobsByStatusScope
        self.findingsByKey = findingsByKey
        self.durationSeconds = durationSeconds
        self.dockerOOMTotal = dockerOOMTotal
        self.archiveBytes = archiveBytes
    }
}

extension Store {
    public func listContextNotes(includeDeleted: Bool = false) throws -> [ContextNote] {
        try read { db in
            let sql = includeDeleted
                ? "SELECT * FROM context_notes ORDER BY kind, updated_at DESC, id"
                : "SELECT * FROM context_notes WHERE deleted_at IS NULL ORDER BY kind, updated_at DESC, id"
            return try Row.fetchAll(db, sql: sql).map(ContextNote.init(row:))
        }
    }

    public func contextNote(id: String, includeDeleted: Bool = true) throws -> ContextNote? {
        try read { db in
            let sql = includeDeleted
                ? "SELECT * FROM context_notes WHERE id = ?"
                : "SELECT * FROM context_notes WHERE id = ? AND deleted_at IS NULL"
            return try Row.fetchOne(db, sql: sql, arguments: [id]).map(ContextNote.init(row:))
        }
    }

    public func insertContextNote(_ note: ContextNote) throws {
        try write { db in
            try db.execute(
                sql: """
                    INSERT INTO context_notes (
                      id, kind, title, body, path_globs_json, always_include,
                      created_at, updated_at, deleted_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    note.id,
                    note.kind.rawValue,
                    note.title,
                    note.body,
                    encodeJSONArray(note.pathGlobs),
                    note.alwaysInclude ? 1 : 0,
                    ISO8601Dates.string(from: note.createdAt),
                    ISO8601Dates.string(from: note.updatedAt),
                    note.deletedAt.map(ISO8601Dates.string(from:)),
                ]
            )
        }
    }

    public func updateContextNote(_ note: ContextNote) throws {
        try write { db in
            try db.execute(
                sql: """
                    UPDATE context_notes SET
                      kind = ?, title = ?, body = ?, path_globs_json = ?,
                      always_include = ?, updated_at = ?, deleted_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    note.kind.rawValue,
                    note.title,
                    note.body,
                    encodeJSONArray(note.pathGlobs),
                    note.alwaysInclude ? 1 : 0,
                    ISO8601Dates.string(from: note.updatedAt),
                    note.deletedAt.map(ISO8601Dates.string(from:)),
                    note.id,
                ]
            )
        }
    }

    public func softDeleteContextNote(id: String, at now: Date = Date()) throws -> ContextNote? {
        guard var note = try contextNote(id: id) else { return nil }
        if note.deletedAt == nil {
            note.deletedAt = now
            note.updatedAt = now
            try updateContextNote(note)
        }
        try deleteChunks(kind: note.kind == .architecture ? .architecture : .user, ref: note.id)
        return note
    }

    public func acceptedArchitectureNote() throws -> ContextNote? {
        try read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM context_notes
                    WHERE kind = 'architecture' AND deleted_at IS NULL
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """
            ).map(ContextNote.init(row:))
        }
    }

    public func upsertChunks(_ chunks: [ContextChunk]) throws {
        guard !chunks.isEmpty else { return }
        try write { db in
            for chunk in chunks {
                try db.execute(
                    sql: """
                        INSERT INTO context_chunks (
                          id, kind, ref, ordinal, text, embedding, embedding_model,
                          content_sha256, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                          text = excluded.text,
                          embedding = excluded.embedding,
                          embedding_model = excluded.embedding_model,
                          content_sha256 = excluded.content_sha256,
                          updated_at = excluded.updated_at,
                          ordinal = excluded.ordinal
                        """,
                    arguments: [
                        chunk.id,
                        chunk.kind.rawValue,
                        chunk.ref,
                        chunk.ordinal,
                        chunk.text,
                        chunk.embedding,
                        chunk.embeddingModel,
                        chunk.contentSHA256,
                        ISO8601Dates.string(from: chunk.updatedAt),
                    ]
                )
            }
        }
    }

    public func chunks(kind: ChunkKind, ref: String? = nil) throws -> [ContextChunk] {
        try read { db in
            if let ref {
                return try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM context_chunks WHERE kind = ? AND ref = ? ORDER BY ordinal, id",
                    arguments: [kind.rawValue, ref]
                ).map(ContextChunk.init(row:))
            }
            return try Row.fetchAll(
                db,
                sql: "SELECT * FROM context_chunks WHERE kind = ? ORDER BY ref, ordinal, id",
                arguments: [kind.rawValue]
            ).map(ContextChunk.init(row:))
        }
    }

    public func deleteChunks(kind: ChunkKind, ref: String? = nil) throws {
        try write { db in
            if let ref {
                try db.execute(
                    sql: "DELETE FROM context_chunks WHERE kind = ? AND ref = ?",
                    arguments: [kind.rawValue, ref]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM context_chunks WHERE kind = ?",
                    arguments: [kind.rawValue]
                )
            }
        }
    }

    public func deleteChunks(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM context_chunks WHERE id = ?", arguments: [id])
            }
        }
    }

    public func retrieveChunks(
        query: [Float],
        k: Int,
        includeAlways: Bool = true
    ) throws -> [ContextRetrieveHit] {
        let all = try read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM context_chunks").map(ContextChunk.init(row:))
        }
        var hits: [ContextRetrieveHit] = []
        hits.reserveCapacity(all.count)
        for chunk in all {
            guard let blob = chunk.embedding else { continue }
            let vector = EmbeddingVector.decode(blob)
            guard !vector.isEmpty else { continue }
            hits.append(ContextRetrieveHit(chunk: chunk, score: EmbeddingVector.cosine(query, vector)))
        }
        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.chunk.id < rhs.chunk.id
        }
        var selected = Array(hits.prefix(max(k, 0)))
        if includeAlways {
            let notes = try listContextNotes()
            let alwaysIDs = Set(notes.filter(\.alwaysInclude).map(\.id))
            if !alwaysIDs.isEmpty {
                var already = Set(selected.map(\.chunk.id))
                for chunk in all where alwaysIDs.contains(chunk.ref) && !already.contains(chunk.id) {
                    selected.append(ContextRetrieveHit(chunk: chunk, score: 1))
                    already.insert(chunk.id)
                }
            }
        }
        return selected
    }

    public func listLearnings(status: LearningStatus? = .pending, kind: LearningKind? = nil) throws -> [Learning] {
        try read { db in
            var clauses: [String] = []
            var arguments: [any DatabaseValueConvertible] = []
            if let status {
                clauses.append("status = ?")
                arguments.append(status.rawValue)
            }
            if let kind {
                clauses.append("kind = ?")
                arguments.append(kind.rawValue)
            }
            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            return try Row.fetchAll(
                db,
                sql: "SELECT * FROM learnings \(whereSQL) ORDER BY created_at DESC, id",
                arguments: StatementArguments(arguments)
            ).map(Learning.init(row:))
        }
    }

    public func learning(id: String) throws -> Learning? {
        try read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM learnings WHERE id = ?", arguments: [id])
                .map(Learning.init(row:))
        }
    }

    public func insertLearning(_ learning: Learning) throws {
        try write { db in
            try db.execute(
                sql: """
                    INSERT INTO learnings (
                      id, job_id, kind, status, title, body, payload_json, created_at, resolved_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    learning.id,
                    learning.jobID?.rawValue,
                    learning.kind.rawValue,
                    learning.status.rawValue,
                    learning.title,
                    learning.body,
                    learning.payloadJSON,
                    ISO8601Dates.string(from: learning.createdAt),
                    learning.resolvedAt.map(ISO8601Dates.string(from:)),
                ]
            )
        }
    }

    public func updateLearning(_ learning: Learning) throws {
        try write { db in
            try db.execute(
                sql: """
                    UPDATE learnings SET
                      status = ?, title = ?, body = ?, payload_json = ?, resolved_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    learning.status.rawValue,
                    learning.title,
                    learning.body,
                    learning.payloadJSON,
                    learning.resolvedAt.map(ISO8601Dates.string(from:)),
                    learning.id,
                ]
            )
        }
    }

    public func metricsSnapshot() throws -> MetricsSnapshot {
        try read { db in
            let queueDepth = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM jobs WHERE status = 'queued'"
            ) ?? 0
            var jobsByStatusScope: [String: Int] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT status, scope, COUNT(*) AS n FROM jobs GROUP BY status, scope"
            ) {
                let status = row["status"] as String? ?? ""
                let scope = row["scope"] as String? ?? ""
                jobsByStatusScope["\(status)|\(scope)"] = row["n"] as Int? ?? 0
            }
            var findingsByKey: [String: Int] = [:]
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT phase, COALESCE(judge_verdict, 'none') AS verdict,
                           severity, COUNT(*) AS n
                    FROM findings
                    GROUP BY phase, verdict, severity
                    """
            ) {
                let phase = row["phase"] as String? ?? ""
                let verdict = row["verdict"] as String? ?? "none"
                let severity = row["severity"] as String? ?? ""
                findingsByKey["\(phase)|\(verdict)|\(severity)"] = row["n"] as Int? ?? 0
            }
            var sums: [String: Double] = [
                "unpack": 0, "identify": 0, "deterministic": 0, "review": 0, "judge": 0,
            ]
            var counts: [String: Double] = sums
            for row in try Row.fetchAll(db, sql: "SELECT timings_json FROM jobs WHERE timings_json IS NOT NULL") {
                guard let raw = row["timings_json"] as String?,
                      let data = raw.data(using: .utf8),
                      let timings = try? JSONDecoder().decode(JobTimings.self, from: data)
                else { continue }
                func add(_ key: String, _ ms: Int?) {
                    guard let ms else { return }
                    sums[key, default: 0] += Double(ms) / 1000.0
                    counts[key, default: 0] += 1
                }
                add("unpack", timings.unpackMS)
                add("identify", timings.identifyMS)
                add("deterministic", timings.deterministicMS)
                add("review", timings.reviewMS)
                add("judge", timings.judgeMS)
            }
            var duration: [String: Double] = [:]
            for key in sums.keys {
                let n = counts[key] ?? 0
                duration[key] = n > 0 ? (sums[key] ?? 0) / n : 0
            }
            let oom = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM job_events WHERE message LIKE '%oom%'"
            ) ?? 0
            let archiveBytes = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(archive_bytes), 0) FROM jobs"
            ) ?? 0
            return MetricsSnapshot(
                queueDepth: queueDepth,
                jobsByStatusScope: jobsByStatusScope,
                findingsByKey: findingsByKey,
                durationSeconds: duration,
                dockerOOMTotal: oom,
                archiveBytes: archiveBytes
            )
        }
    }
}

extension ContextNote {
    fileprivate init(row: Row) {
        let globs = decodeJSONArray(row["path_globs_json"] as String?)
        let always: Bool
        if let raw = row["always_include"] as Int? {
            always = raw != 0
        } else {
            always = row["always_include"] as Bool? ?? false
        }
        self.init(
            id: row["id"] as String? ?? "",
            kind: ContextNoteKind(rawValue: row["kind"] as String? ?? "") ?? .user,
            title: row["title"] as String? ?? "",
            body: row["body"] as String? ?? "",
            pathGlobs: globs,
            alwaysInclude: always,
            createdAt: ISO8601Dates.date(from: row["created_at"] as String? ?? "") ?? Date(),
            updatedAt: ISO8601Dates.date(from: row["updated_at"] as String? ?? "") ?? Date(),
            deletedAt: (row["deleted_at"] as String?).flatMap(ISO8601Dates.date(from:))
        )
    }
}

extension ContextChunk {
    fileprivate init(row: Row) {
        self.init(
            id: row["id"] as String? ?? "",
            kind: ChunkKind(rawValue: row["kind"] as String? ?? "") ?? .file,
            ref: row["ref"] as String? ?? "",
            ordinal: row["ordinal"] as Int? ?? 0,
            text: row["text"] as String? ?? "",
            embedding: row["embedding"] as Data?,
            embeddingModel: row["embedding_model"] as String?,
            contentSHA256: row["content_sha256"] as String? ?? "",
            updatedAt: ISO8601Dates.date(from: row["updated_at"] as String? ?? "") ?? Date()
        )
    }
}

extension Learning {
    fileprivate init(row: Row) {
        self.init(
            id: row["id"] as String? ?? "",
            jobID: (row["job_id"] as String?).map { JobID($0) },
            kind: LearningKind(rawValue: row["kind"] as String? ?? "") ?? .context,
            status: LearningStatus(rawValue: row["status"] as String? ?? "") ?? .pending,
            title: row["title"] as String? ?? "",
            body: row["body"] as String? ?? "",
            payloadJSON: row["payload_json"] as String?,
            createdAt: ISO8601Dates.date(from: row["created_at"] as String? ?? "") ?? Date(),
            resolvedAt: (row["resolved_at"] as String?).flatMap(ISO8601Dates.date(from:))
        )
    }
}

private func encodeJSONArray(_ values: [String]) -> String {
    guard let data = try? JSONEncoder().encode(values),
          let text = String(data: data, encoding: .utf8)
    else { return "[]" }
    return text
}

private func decodeJSONArray(_ raw: String?) -> [String] {
    guard let raw, let data = raw.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
}
