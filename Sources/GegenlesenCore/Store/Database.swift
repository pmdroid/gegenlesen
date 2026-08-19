import Foundation
import GRDB

/// All SQLite access. One GRDB `DatabasePool` per process.
public actor Store {
    public nonisolated let blobs: BlobStore
    public nonisolated let sqliteURL: URL
    let pool: DatabasePool

    public static func open(dataDir: URL) throws -> Store {
        let blobs = BlobStore(root: dataDir)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try blobs.ensureLayout()

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: blobs.sqliteURL.path, configuration: configuration)
        try Migrations.migrator.migrate(pool)
        return Store(pool: pool, blobs: blobs)
    }

    init(pool: DatabasePool, blobs: BlobStore) {
        self.pool = pool
        self.blobs = blobs
        self.sqliteURL = blobs.sqliteURL
    }

    public func read<T: Sendable>(_ value: @Sendable (Database) throws -> T) throws -> T {
        try pool.read(value)
    }

    public func write<T: Sendable>(_ updates: @Sendable (Database) throws -> T) throws -> T {
        try pool.write(updates)
    }

    public func appliedMigrationIdentifiers() throws -> Set<String> {
        try pool.read { db in
            try Migrations.migrator.appliedIdentifiers(db)
        }
    }

    public func tableExists(_ name: String) throws -> Bool {
        try pool.read { db in
            try db.tableExists(name)
        }
    }

    public func columnNames(in table: String) throws -> [String] {
        try pool.read { db in
            try db.columns(in: table).map(\.name)
        }
    }

    public func userTableNames() throws -> [String] {
        try pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table'
                      AND name NOT LIKE 'sqlite_%'
                      AND name NOT LIKE 'grdb_%'
                      AND name NOT LIKE '%_fts_%'
                    ORDER BY name
                    """
            )
        }
    }
}
