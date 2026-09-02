import Testing
@testable import ReloraData
import GRDB

@Suite("AppDatabase migration and health check")
struct AppDatabaseTests {
    private let allTables = [
        "contacts", "key_things", "memories", "reminders",
        "voice_note_usage_events", "sync_state", "search_index_meta",
        "app_settings", "contact_search"
    ]

    @Test("v9-baseline migration creates every table")
    func migrationCreatesAllTables() throws {
        let database = try Fixtures.makeDatabase()
        try database.read { db in
            for table in allTables {
                let exists = try Row.fetchOne(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'view') AND name = ?",
                    arguments: [table]
                ) != nil
                #expect(exists, "expected table \(table) to exist after migration")
            }
        }
    }

    @Test("PRAGMA user_version is 9 after migration")
    func userVersionIsNine() throws {
        let database = try Fixtures.makeDatabase()
        let version = try database.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version")
        }
        #expect(version == 9)
    }

    @Test("migration seeds sync_state and search_index_meta rows")
    func migrationSeedsSingletonRows() throws {
        let database = try Fixtures.makeDatabase()
        try database.read { db in
            let syncStateExists = try Row.fetchOne(db, sql: "SELECT id FROM sync_state WHERE id = 1") != nil
            #expect(syncStateExists)

            let rebuildFlag = try String.fetchOne(
                db,
                sql: "SELECT value FROM search_index_meta WHERE key = 'contact_search_needs_rebuild'"
            )
            #expect(rebuildFlag == "1")
        }
    }

    @Test("health check passes on a freshly migrated database")
    func healthCheckPasses() throws {
        let database = try Fixtures.makeDatabase()
        let health = try database.healthCheck()
        #expect(health.foreignKeysEnabled)
        #expect(health.hasContactSearchTable)
        #expect(health.sqliteVersion != nil)
    }

    @Test("foreign keys are enforced")
    func foreignKeysEnforced() throws {
        let database = try Fixtures.makeDatabase()
        #expect(throws: (any Error).self) {
            try database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO key_things (id, contact_id, user_id, text, source, created_at, updated_at)
                        VALUES ('kt-1', 'missing-contact', 'user-1', 'text', 'manual', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                        """
                )
            }
        }
    }

    @Test("migration is idempotent across repeated on-disk opens")
    func migrationIsIdempotentOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbURL = directory.appendingPathComponent("relora.db")

        let first = try AppDatabase.onDisk(url: dbURL)
        try first.healthCheck()

        let second = try AppDatabase.onDisk(url: dbURL)
        let health = try second.healthCheck()
        #expect(health.foreignKeysEnabled)
    }
}
