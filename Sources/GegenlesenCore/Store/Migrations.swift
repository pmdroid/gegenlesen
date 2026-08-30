import GRDB

public enum Migrations {
    public static let v1Initial = "v1_initial"
    public static let v2Repositories = "v2_repositories"
    public static let v3Risk = "v3_risk"
    public static let v4SlotEngines = "v4_slot_engines"

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(v1Initial, migrate: migrateV1Initial)
        migrator.registerMigration(v2Repositories, migrate: migrateV2Repositories)
        migrator.registerMigration(v3Risk, migrate: migrateV3Risk)
        migrator.registerMigration(v4SlotEngines, migrate: migrateV4SlotEngines)
        return migrator
    }

    private static func migrateV1Initial(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE jobs (
              id            TEXT PRIMARY KEY,
              created_at    TEXT NOT NULL,
              updated_at    TEXT NOT NULL,
              started_at    TEXT,
              finished_at   TEXT,
              status        TEXT NOT NULL,
              scope         TEXT NOT NULL,
              parent_job_id TEXT REFERENCES jobs(id),
              title         TEXT,
              reviewer_a_model_id TEXT NOT NULL,
              reviewer_b_model_id TEXT NOT NULL,
              judge_model_id      TEXT NOT NULL,
              base_sha      TEXT,
              head_sha      TEXT,
              default_branch TEXT,
              archive_sha256 TEXT,
              archive_bytes INTEGER,
              file_count    INTEGER,
              error_message TEXT,
              container_name TEXT,
              container_name_a TEXT,
              container_name_b TEXT,
              timings_json  TEXT
            );

            CREATE TABLE job_files (
              job_id     TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
              path       TEXT NOT NULL,
              sha256     TEXT,
              status     TEXT NOT NULL,
              old_path   TEXT,
              language   TEXT,
              bytes      INTEGER,
              PRIMARY KEY (job_id, path)
            );

            CREATE TABLE job_events (
              id         INTEGER PRIMARY KEY AUTOINCREMENT,
              job_id     TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
              ts         TEXT NOT NULL,
              level      TEXT NOT NULL,
              message    TEXT NOT NULL,
              payload_json TEXT
            );
            CREATE INDEX job_events_job_ts ON job_events(job_id, id);

            CREATE TABLE findings (
              id                 TEXT PRIMARY KEY,
              job_id             TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
              rule_id            TEXT,
              phase              TEXT NOT NULL,
              reviewer_slot      TEXT,
              severity           TEXT NOT NULL,
              title              TEXT NOT NULL,
              message            TEXT NOT NULL,
              file_path          TEXT,
              start_line         INTEGER,
              end_line           INTEGER,
              snippet            TEXT,
              agent_rationale    TEXT,
              judge_verdict      TEXT,
              judge_severity     TEXT,
              judge_rationale    TEXT,
              confidence         REAL,
              lifecycle          TEXT NOT NULL DEFAULT 'new',
              parent_finding_id  TEXT,
              suggested_patch    TEXT,
              fingerprint        TEXT,
              evidence_ok        INTEGER,
              created_at         TEXT NOT NULL
            );
            CREATE INDEX findings_job ON findings(job_id);
            CREATE INDEX findings_fp ON findings(fingerprint);

            CREATE TABLE rules (
              id                    TEXT PRIMARY KEY,
              title                 TEXT NOT NULL,
              severity              TEXT NOT NULL,
              kind                  TEXT NOT NULL,
              enabled               INTEGER NOT NULL DEFAULT 1,
              deleted_at            TEXT,
              provenance            TEXT NOT NULL,
              languages_json        TEXT NOT NULL,
              path_globs_json       TEXT NOT NULL,
              payload_json          TEXT NOT NULL,
              examples_json         TEXT NOT NULL DEFAULT '[]',
              source_pr_refs_json   TEXT NOT NULL DEFAULT '[]',
              promoted_from_rule_id TEXT,
              body_md               TEXT NOT NULL DEFAULT '',
              created_at            TEXT NOT NULL,
              updated_at            TEXT NOT NULL
            );

            CREATE VIRTUAL TABLE rules_fts USING fts5(
              title, body_md, examples, payload,
              content='',
              tokenize = 'porter'
            );

            CREATE TABLE finding_feedback (
              id           INTEGER PRIMARY KEY AUTOINCREMENT,
              finding_id   TEXT NOT NULL REFERENCES findings(id) ON DELETE CASCADE,
              job_id       TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
              ts           TEXT NOT NULL,
              verdict      TEXT NOT NULL,
              reaction     TEXT,
              comment      TEXT,
              suggested_rule_id TEXT REFERENCES rules(id)
            );
            CREATE INDEX finding_feedback_finding ON finding_feedback(finding_id);

            CREATE TABLE context_notes (
              id              TEXT PRIMARY KEY,
              kind            TEXT NOT NULL,
              title           TEXT NOT NULL,
              body            TEXT NOT NULL,
              path_globs_json TEXT NOT NULL DEFAULT '[]',
              always_include  INTEGER NOT NULL DEFAULT 0,
              created_at      TEXT NOT NULL,
              updated_at      TEXT NOT NULL,
              deleted_at      TEXT
            );

            CREATE TABLE context_chunks (
              id               TEXT PRIMARY KEY,
              kind             TEXT NOT NULL,
              ref              TEXT NOT NULL,
              ordinal          INTEGER NOT NULL DEFAULT 0,
              text             TEXT NOT NULL,
              embedding        BLOB,
              embedding_model  TEXT,
              content_sha256   TEXT NOT NULL,
              updated_at       TEXT NOT NULL
            );
            CREATE INDEX context_chunks_kind_ref ON context_chunks(kind, ref);

            CREATE TABLE learnings (
              id           TEXT PRIMARY KEY,
              job_id       TEXT REFERENCES jobs(id),
              kind         TEXT NOT NULL,
              status       TEXT NOT NULL,
              title        TEXT NOT NULL,
              body         TEXT NOT NULL,
              payload_json TEXT,
              created_at   TEXT NOT NULL,
              resolved_at  TEXT
            );
            CREATE INDEX learnings_status ON learnings(status);

            CREATE TABLE corpus_items (
              id            TEXT PRIMARY KEY,
              source_label  TEXT NOT NULL,
              title         TEXT,
              body          TEXT,
              comments_json TEXT,
              patch_relpath TEXT NOT NULL,
              mined_at      TEXT,
              created_at    TEXT NOT NULL
            );
            """)
    }

    private static func migrateV2Repositories(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE jobs ADD COLUMN repository TEXT")
        try db.execute(sql: "ALTER TABLE rules ADD COLUMN repository TEXT")
        try db.execute(sql: "ALTER TABLE context_notes ADD COLUMN repository TEXT")
        try db.execute(sql: "CREATE INDEX jobs_repository ON jobs(repository)")
        try db.execute(sql: "CREATE INDEX rules_repository ON rules(repository)")
        try db.execute(sql: "CREATE INDEX context_notes_repository ON context_notes(repository)")
    }

    private static func migrateV3Risk(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE jobs ADD COLUMN risk_verdict TEXT")
        try db.execute(sql: "ALTER TABLE jobs ADD COLUMN risk_json TEXT")
    }

    private static func migrateV4SlotEngines(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE jobs ADD COLUMN reviewer_a_engine TEXT NOT NULL DEFAULT 'opencode'")
        try db.execute(sql: "ALTER TABLE jobs ADD COLUMN reviewer_b_engine TEXT NOT NULL DEFAULT 'opencode'")
        try db.execute(sql: "ALTER TABLE jobs ADD COLUMN judge_engine TEXT NOT NULL DEFAULT 'opencode'")
    }
}
