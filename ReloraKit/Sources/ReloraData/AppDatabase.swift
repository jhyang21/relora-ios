import Foundation
import GRDB

/// Where the on-disk database file lives. Kept separate from `AppDatabase` so
/// tests and diagnostics can compute the path without opening a connection.
public enum DatabaseLocation {
    public enum LocationError: Error, Equatable, Sendable {
        case applicationSupportUnavailable(String)
    }

    /// `Application Support/Relora/relora.db`, creating the `Relora` directory
    /// (and excluding it from iCloud/iTunes backup would be a product decision
    /// made elsewhere — this helper only guarantees the directory exists).
    public static func defaultDatabaseURL() throws -> URL {
        let fileManager = FileManager.default
        let appSupport: URL
        do {
            appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw LocationError.applicationSupportUnavailable(error.localizedDescription)
        }
        let directory = appSupport.appendingPathComponent("Relora", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Already the platform default; stated so a future iOS default
        // cannot quietly weaken it. Deliberately NOT `.complete`: sync
        // writes while the app is backgrounded, and a locked device would
        // fail every one of those writes.
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        return directory.appendingPathComponent("relora.db", isDirectory: false)
    }
}

/// Required tables the health check asserts exist, matching `REQUIRED_TABLES`
/// in apps/mobile/src/db/client.ts.
public struct DatabaseHealth: Equatable, Sendable {
    public var sqliteVersion: String?
    public var foreignKeysEnabled: Bool
    public var hasContactSearchTable: Bool
}

public enum DatabaseHealthError: Error, Equatable, Sendable {
    case missingTables([String])
    case foreignKeysDisabled
}

/// Owns the GRDB connection (a `DatabasePool` on disk, a `DatabaseQueue` in
/// memory for tests) and applies the schema migration on construction —
/// mirroring `getDb()` in client.ts, which opens once, migrates, then hands
/// out the same instance.
public final class AppDatabase: Sendable {
    /// `any DatabaseWriter` covers both `DatabasePool` and `DatabaseQueue`;
    /// GRDB 7 makes both `Sendable`, and `AppDatabase` itself holds no other
    /// mutable state, so it is safe to share across concurrency domains.
    private let dbWriter: any DatabaseWriter

    private init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try Self.migrator.migrate(dbWriter)
    }

    /// Opens (creating if needed) the on-disk database at
    /// `DatabaseLocation.defaultDatabaseURL()`. `DatabasePool` manages its own
    /// WAL journal mode — GRDB requires it and sets it up on first connection,
    /// so nothing here sets `PRAGMA journal_mode` by hand.
    public static func onDisk(url: URL? = nil) throws -> AppDatabase {
        let databaseURL = try url ?? DatabaseLocation.defaultDatabaseURL()
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        return try AppDatabase(pool)
    }

    /// An in-memory database for tests: a single-connection `DatabaseQueue`,
    /// migrated the same way as the on-disk pool, discarded with the process.
    public static func inMemory() throws -> AppDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        return try AppDatabase(queue)
    }

    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.read(block)
    }

    @discardableResult
    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.write(block)
    }

    /// Runs `block` on the writer connection without GRDB's automatic
    /// transaction wrapper. SQLite refuses to change `PRAGMA foreign_keys`
    /// while a transaction is open, so anything that needs to toggle it
    /// around an explicit `Database.inTransaction` block — currently only
    /// `GuestMigration`'s ownership rewrite — must go through this instead
    /// of `write`.
    @discardableResult
    public func writeWithoutTransaction<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.writeWithoutTransaction(block)
    }

    /// Yields a fresh value every time a committed write changes what `fetch`
    /// would return, starting with the value as it is now.
    ///
    /// Wrapped in an `AsyncStream` rather than handing back GRDB's own
    /// `ValueObservation` so a feature can observe the database with
    /// `for await` and no GRDB import — the same reason every other query in
    /// this module is a repository method rather than exposed SQL.
    ///
    /// Values arrive on the main queue, which is where the view models
    /// consuming them live. An observation error finishes the stream; the
    /// caller keeps whatever it last received rather than blanking the screen,
    /// which is the right failure for a list of someone's notes.
    public func observe<T: Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> T
    ) -> AsyncStream<T> {
        AsyncStream { continuation in
            let cancellable = ValueObservation.tracking(fetch).start(
                in: dbWriter,
                scheduling: .async(onQueue: .main),
                onError: { _ in continuation.finish() },
                onChange: { continuation.yield($0) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    /// Fires whenever anything in the user's content tables changes.
    ///
    /// A change *token*, not the data. Screens reload through the repositories
    /// they already use, so the observation does not need a second copy of every
    /// query written against a bare `Database`, and the repositories stay the one
    /// place a table is read.
    ///
    /// The token is counts and high-water `updated_at` marks, which is enough to
    /// notice every write the app makes: inserts and deletes move the count,
    /// edits move `updated_at`, and a soft delete or a restore is an edit. The
    /// value itself is meaningless to the caller — only that it changed matters.
    /// GRDB derives the tracked region from the statement, so reading all four
    /// tables here is what makes a write to any of them refire.
    public func observeContentChanges() -> AsyncStream<String> {
        observe { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT
                      (SELECT COUNT(*) FROM contacts) || '/' ||
                      COALESCE((SELECT MAX(updated_at) FROM contacts), '') || '|' ||
                      (SELECT COUNT(*) FROM memories) || '/' ||
                      COALESCE((SELECT MAX(updated_at) FROM memories), '') || '|' ||
                      (SELECT COUNT(*) FROM key_things) || '/' ||
                      COALESCE((SELECT MAX(updated_at) FROM key_things), '') || '|' ||
                      (SELECT COUNT(*) FROM reminders) || '/' ||
                      COALESCE((SELECT MAX(updated_at) FROM reminders), '')
                    """
            ) ?? ""
        }
    }

    /// The tables `runInitHealthCheck` in client.ts asserts exist before the
    /// app is allowed to proceed.
    public static let requiredTables = [
        "contacts",
        "memories",
        "key_things",
        "reminders",
        "voice_note_usage_events",
        "sync_state",
        "app_settings"
    ]

    /// Mirrors `runInitHealthCheck` in client.ts: asserts every required table
    /// exists and that SQLite foreign key enforcement is on, throwing
    /// `DatabaseHealthError` otherwise. `hasContactSearchTable` is informational
    /// only — the RN version logs it but never fails the check on it, since a
    /// missing FTS table degrades to the LIKE fallback rather than being fatal.
    @discardableResult
    public func healthCheck() throws -> DatabaseHealth {
        try read { db in
            let sqliteVersion = try String.fetchOne(db, sql: "SELECT sqlite_version()")
            let foreignKeysRow = try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
            let foreignKeysEnabled = foreignKeysRow == 1

            let placeholders = Self.requiredTables.map { _ in "?" }.joined(separator: ", ")
            let existingRows = try Row.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (\(placeholders))",
                arguments: StatementArguments(Self.requiredTables.map { $0 as DatabaseValueConvertible? })
            )
            let existingNames = Set(existingRows.map { row -> String in row["name"] })
            let missing = Self.requiredTables.filter { !existingNames.contains($0) }

            let hasContactSearchTable = try Row.fetchOne(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'contact_search' LIMIT 1"
            ) != nil

            if !missing.isEmpty {
                throw DatabaseHealthError.missingTables(missing)
            }
            if !foreignKeysEnabled {
                throw DatabaseHealthError.foreignKeysDisabled
            }

            return DatabaseHealth(
                sqliteVersion: sqliteVersion,
                foreignKeysEnabled: foreignKeysEnabled,
                hasContactSearchTable: hasContactSearchTable
            )
        }
    }

    /// A single migration named "v9-baseline": the native app takes a clean
    /// cut of the schema at RN schema version 9 rather than replaying nine
    /// incremental migrations that have no local data to act on. `PRAGMA
    /// user_version = 9` is set for provenance alongside GRDB's own migration
    /// bookkeeping (which tracks applied migrations by identifier in its own
    /// table, independent of `user_version`).
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v9-baseline") { db in
            for statement in SchemaSQL.migrationStatements {
                try db.execute(sql: statement)
            }
            try db.execute(sql: "PRAGMA user_version = 9")
        }
        return migrator
    }
}
