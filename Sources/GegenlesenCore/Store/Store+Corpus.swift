import Foundation
import GRDB

extension Store {
    public func insertCorpusItem(_ item: CorpusItem) throws {
        try write { db in
            try db.execute(
                sql: """
                    INSERT INTO corpus_items (
                      id, source_label, title, body, comments_json,
                      patch_relpath, mined_at, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    item.id,
                    item.sourceLabel,
                    item.title,
                    item.body,
                    item.commentsJSON,
                    item.patchRelpath,
                    item.minedAt.map(ISO8601Dates.string(from:)),
                    ISO8601Dates.string(from: item.createdAt),
                ]
            )
        }
    }

    public func corpusItem(id: String) throws -> CorpusItem? {
        try read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM corpus_items WHERE id = ?",
                arguments: [id]
            ).map(CorpusItem.init(row:))
        }
    }

    public func listCorpusItems() throws -> [CorpusItem] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM corpus_items ORDER BY created_at DESC, id DESC"
            ).map(CorpusItem.init(row:))
        }
    }

    public func markCorpusMined(ids: [String], at now: Date = Date()) throws {
        guard !ids.isEmpty else { return }
        let stamp = ISO8601Dates.string(from: now)
        try write { db in
            for id in ids {
                try db.execute(
                    sql: "UPDATE corpus_items SET mined_at = ? WHERE id = ?",
                    arguments: [stamp, id]
                )
            }
        }
    }
}

extension CorpusItem {
    fileprivate init(row: Row) {
        self.init(
            id: row["id"] as String? ?? "",
            sourceLabel: row["source_label"] as String? ?? "",
            title: row["title"] as String?,
            body: row["body"] as String?,
            commentsJSON: row["comments_json"] as String?,
            patchRelpath: row["patch_relpath"] as String? ?? "",
            minedAt: (row["mined_at"] as String?).flatMap(ISO8601Dates.date(from:)),
            createdAt: ISO8601Dates.date(from: row["created_at"] as String? ?? "") ?? Date()
        )
    }
}
