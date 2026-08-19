import Foundation
import GRDB
import Testing
@testable import GegenlesenCore

@Suite
struct StoreTests {
    @Test
    func openAppliesV1InitialAndIsIdempotent() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let first = try await store.appliedMigrationIdentifiers()
            #expect(first == [Migrations.v1Initial, Migrations.v2Repositories, Migrations.v3Risk])

            let reopened = try Store.open(dataDir: dir)
            let second = try await reopened.appliedMigrationIdentifiers()
            #expect(second == [Migrations.v1Initial, Migrations.v2Repositories, Migrations.v3Risk])
        }
    }

    @Test
    func v1SchemaHasExpectedTablesAndNoSettings() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let tables = try await store.userTableNames()
            #expect(Set(tables) == Set([
                "jobs",
                "job_files",
                "job_events",
                "findings",
                "rules",
                "rules_fts",
                "finding_feedback",
                "context_notes",
                "context_chunks",
                "learnings",
                "corpus_items",
            ]))
            #expect(!(try await store.tableExists("settings")))

            let findingColumns = try await store.columnNames(in: "findings")
            #expect(findingColumns.contains("reviewer_slot"))

            let jobColumns = try await store.columnNames(in: "jobs")
            #expect(jobColumns.contains("container_name_a"))
            #expect(jobColumns.contains("container_name_b"))
            #expect(jobColumns.contains("repository"))
            #expect(jobColumns.contains("risk_verdict"))
            #expect(jobColumns.contains("risk_json"))
            let ruleColumns = try await store.columnNames(in: "rules")
            #expect(ruleColumns.contains("repository"))
            let noteColumns = try await store.columnNames(in: "context_notes")
            #expect(noteColumns.contains("repository"))
        }
    }

    @Test
    func rulesFTSIsContentlessAndSearchable() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await store.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO rules (
                          id, title, severity, kind, enabled, provenance,
                          languages_json, path_globs_json, payload_json,
                          body_md, created_at, updated_at
                        ) VALUES (
                          'no-eval', 'Ban eval', 'error', 'deterministic', 1, 'handwritten',
                          '["javascript"]', '["**/*.js"]', '{"checker":"regex","pattern":"eval("}',
                          'Do not call eval', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
                        )
                        """
                )
                try db.execute(
                    sql: """
                        INSERT INTO rules_fts(title, body_md, examples, payload)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        "Ban eval",
                        "Do not call eval",
                        "[]",
                        "{\"checker\":\"regex\",\"pattern\":\"eval(\"}",
                    ]
                )
            }

            // contentless FTS stores only the index; columns read back as NULL
            let hits = try await store.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM rules_fts WHERE rules_fts MATCH ?",
                    arguments: ["eval"]
                )
            }
            #expect(hits == 1)
        }
    }

    @Test
    func insertRuleMapsColumnsIntoFTS() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            try await store.insertRule(
                Rule(
                    id: RuleID("ban-eval"),
                    title: "Ban eval",
                    severity: .error,
                    kind: .semantic,
                    languages: ["javascript"],
                    pathGlobs: ["**/*.js"],
                    payload: .semantic(instruction: "Do not call eval", fewShots: []),
                    createdAt: now,
                    updatedAt: now
                )
            )
            let scores = try await store.ftsBM25Scores(query: "\"eval\"")
            #expect(scores[RuleID("ban-eval")] != nil)
        }
    }

    @Test
    func foreignKeysRejectOrphanJobFiles() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            await #expect(throws: DatabaseError.self) {
                try await store.write { db in
                    try db.execute(
                        sql: """
                            INSERT INTO job_files (job_id, path, status)
                            VALUES ('missing', 'Sources/A.swift', 'added')
                            """
                    )
                }
            }
        }
    }

    @Test
    func insertJobAndFindingWithReviewerSlot() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await store.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO jobs (
                          id, created_at, updated_at, status, scope,
                          reviewer_a_model_id, reviewer_b_model_id, judge_model_id
                        ) VALUES (
                          'job-1', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z',
                          'queued', 'full', 'anthropic/claude-sonnet-4-5',
                          'openai/gpt-5.2', 'anthropic/claude-sonnet-4-5'
                        )
                        """
                )
                try db.execute(
                    sql: """
                        INSERT INTO findings (
                          id, job_id, phase, reviewer_slot, severity,
                          title, message, lifecycle, created_at
                        ) VALUES (
                          'fnd_01TEST', 'job-1', 'agent', 'model_a', 'error',
                          'Hardcoded secret', 'token assigned', 'new',
                          '2026-01-01T00:00:00Z'
                        )
                        """
                )
            }

            let slot = try await store.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT reviewer_slot FROM findings WHERE id = ?",
                    arguments: ["fnd_01TEST"]
                )
            }
            #expect(slot == "model_a")
        }
    }

    @Test
    func insertFindingsPersistsRequiresJudge() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            let job = Job(
                id: JobID("job-cmd"),
                createdAt: now,
                updatedAt: now,
                status: .queued,
                scope: .full,
                reviewerAModelID: "a",
                reviewerBModelID: "b",
                judgeModelID: "j"
            )
            try await store.insertJob(job)
            let command = FindingDraft(
                ruleID: RuleID("cmd"),
                phase: .deterministic,
                severity: .error,
                title: "cmd hit",
                message: "from sandbox",
                filePath: "Sources/A.swift",
                startLine: 1,
                endLine: 1,
                snippet: "print(2)",
                requiresJudge: true,
                evidenceOK: true
            )
            let mechanical = FindingDraft(
                ruleID: RuleID("regex"),
                phase: .deterministic,
                severity: .warning,
                title: "regex hit",
                message: "mechanical",
                filePath: "Sources/A.swift",
                startLine: 1,
                endLine: 1,
                snippet: "print(2)"
            )
            _ = try await store.insertFindings([command, mechanical], jobID: job.id)
            let findings = try await store.findings(jobID: job.id)
            let cmd = try #require(findings.first { $0.ruleID?.rawValue == "cmd" })
            #expect(cmd.judgeVerdict == nil)
            #expect(cmd.evidenceOK == true)
            let regex = try #require(findings.first { $0.ruleID?.rawValue == "regex" })
            #expect(regex.judgeVerdict == .keep)
            #expect(regex.evidenceOK == true)
        }
    }

    @Test
    func usesWAL() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let mode = try await store.read { db in
                try String.fetchOne(db, sql: "PRAGMA journal_mode")
            }
            #expect(mode?.lowercased() == "wal")
        }
    }
}

@Suite
struct BlobStoreTests {
    @Test
    func ensureLayoutCreatesExpectedDirectories() async throws {
        try await withTempDataDir { dir in
            let blobs = BlobStore(root: dir)
            try blobs.ensureLayout()

            let fm = FileManager.default
            for url in [
                blobs.archives,
                blobs.patches,
                blobs.transcripts,
                blobs.findings,
                blobs.corpus,
                blobs.workspaces,
            ] {
                var isDir: ObjCBool = false
                #expect(fm.fileExists(atPath: url.path, isDirectory: &isDir))
                #expect(isDir.boolValue)
            }

            #expect(blobs.sqliteURL.lastPathComponent == "gegenlesen.sqlite")
            #expect(blobs.archiveURL(jobID: "abc").lastPathComponent == "abc.tar.gz")
            #expect(blobs.patchURL(jobID: "abc").lastPathComponent == "abc.patch")
            #expect(
                blobs.transcriptURL(jobID: "abc", phase: "review").lastPathComponent
                    == "abc-review.ndjson"
            )
            #expect(
                blobs.findingsURL(jobID: "abc", stage: "pre-judge").lastPathComponent
                    == "abc-pre-judge.json"
            )
        }
    }

    @Test
    func openStoreCreatesLayoutAndSQLiteFile() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            #expect(FileManager.default.fileExists(atPath: store.sqliteURL.path))
            #expect(FileManager.default.fileExists(atPath: store.blobs.archives.path))
            #expect(FileManager.default.fileExists(atPath: store.blobs.workspaces.path))
        }
    }
}


