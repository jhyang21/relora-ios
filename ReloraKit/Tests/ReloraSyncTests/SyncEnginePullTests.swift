import Foundation
import GRDB
import Testing
import ReloraCore
import ReloraData
@testable import ReloraSync

@Suite struct SyncEnginePullTests {

    private func makeEngine(
        database: AppDatabase,
        transport: StubSyncTransport,
        pullPageSize: Int = 500,
        userID: String? = testUserID
    ) -> SyncEngine {
        SyncEngine(
            database: database,
            transport: transport,
            userIDProvider: { userID },
            isOnline: { true },
            pullPageSize: pullPageSize,
            writeDebounceNanoseconds: 0,
            retryDelaysMilliseconds: []
        )
    }

    @Test func pullInsertsNewRowsAndAdvancesTheCursorToTheMaxUpdatedAt() async throws {
        let database = try AppDatabase.inMemory()
        let transport = StubSyncTransport()
        await transport.setServerRows(table: .contacts, rows: [
            serverContactRow(id: "c1", name: "Ada", updatedAt: "2026-01-01T00:00:01.000Z"),
            serverContactRow(id: "c2", name: "Bea", updatedAt: "2026-01-01T00:00:02.000Z")
        ])
        let engine = makeEngine(database: database, transport: transport)

        let outcome = await engine.syncNow(reason: "test")
        #expect(outcome.kind == .succeeded)

        let rows = try database.read { db in try Row.fetchAll(db, sql: "SELECT id, name FROM contacts ORDER BY id") }
        let names: [(String, String)] = rows.map { row in (row["id"], row["name"]) }
        #expect(names[0] == ("c1", "Ada"))
        #expect(names[1] == ("c2", "Bea"))

        let syncState = try SyncStateStore(database: database).read()
        #expect(syncState.userID == testUserID)
        #expect(syncState.serverCursor == "2026-01-01T00:00:02.000Z")
    }

    @Test func pullDrainsMultiplePagesUntilAShortPage() async throws {
        let database = try AppDatabase.inMemory()
        let transport = StubSyncTransport()
        let rows = (0..<5).map { index in
            serverContactRow(id: "c\(index)", name: "N\(index)", updatedAt: "2026-01-01T00:00:0\(index).000Z")
        }
        await transport.setServerRows(table: .contacts, rows: rows)
        let engine = makeEngine(database: database, transport: transport, pullPageSize: 2)

        _ = await engine.syncNow(reason: "test")

        let queries = await transport.pullQueries.filter { $0.table == .contacts }
        #expect(queries.map { ($0.from, $0.to) }.elementsEqual([(0, 1), (2, 3), (4, 5)], by: ==))

        let count = try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM contacts")! }
        #expect(count == 5)
    }

    /// The guard protects a row that is dirty *when the pull writes*, which
    /// on a full sync means a row re-edited after the push read its
    /// snapshot: a row still holding the pushed snapshot is cleaned by this
    /// same sync's push and then legitimately accepts the pulled values.
    @Test func pullDoesNotOverwriteALocallyDirtyRow() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            try SyncFixtures.insertContact(db, id: "c1", name: "Pushed", updatedAt: "2026-01-01T00:00:00.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:00.000Z")
        }
        let transport = StubSyncTransport()
        // The user edits the contact while its push is in flight, so it is
        // dirty again (under a new dirty_at the flag-clear cannot match) by
        // the time the pull applies the server row.
        await transport.setOnUpsert { _, _ in
            try database.write { db in
                try db.execute(
                    sql: "UPDATE contacts SET name = 'LocalEdit', is_dirty = 1, dirty_at = ? WHERE id = 'c1'",
                    arguments: ["2026-01-01T00:00:03.000Z"]
                )
            }
        }
        await transport.setServerRows(table: .contacts, rows: [
            serverContactRow(id: "c1", name: "ServerVersion", updatedAt: "2026-01-01T00:00:05.000Z")
        ])
        let engine = makeEngine(database: database, transport: transport)

        _ = await engine.syncNow(reason: "test")

        let name = try database.read { db in try SyncFixtures.column(db, table: .contacts, id: "c1", column: "name") }
        let stillDirty = try database.read { db in try SyncFixtures.isDirty(db, table: .contacts, id: "c1") }
        #expect(name == "LocalEdit")
        #expect(stillDirty)
    }

    @Test func pullOfATombstoneSurfacesTheLocalNotificationIDForTheCaller() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            try SyncFixtures.insertContact(db, id: "c1", updatedAt: "2026-01-01T00:00:00.000Z")
            try SyncFixtures.insertReminder(
                db, id: "r1", contactID: "c1", remindAt: "2026-02-01T00:00:00.000Z",
                updatedAt: "2026-01-01T00:00:00.000Z", notificationID: "local-notif-1"
            )
        }
        let transport = StubSyncTransport()
        await transport.setServerRows(table: .reminders, rows: [
            serverReminderRow(id: "r1", contactID: "c1", remindAt: "2026-02-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:05.000Z", deletedAt: "2026-01-01T00:00:05.000Z")
        ])
        let engine = makeEngine(database: database, transport: transport)

        let outcome = await engine.syncNow(reason: "test")
        #expect(outcome.pulledReminderTombstoneNotificationIDs == ["local-notif-1"])

        // ReloraSync never touches UNUserNotificationCenter, and it does not
        // clear notification_id itself either — the caller owns that once
        // it has actually cancelled the OS notification.
        let notificationID = try database.read { db in try SyncFixtures.column(db, table: .reminders, id: "r1", column: "notification_id") }
        #expect(notificationID == "local-notif-1")

        let deletedAt = try database.read { db in try SyncFixtures.column(db, table: .reminders, id: "r1", column: "deleted_at") }
        #expect(deletedAt == "2026-01-01T00:00:05.000Z")
    }

    @Test func aTombstoneSkippedByTheDirtyGuardDoesNotSurfaceItsNotificationID() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            try SyncFixtures.insertContact(db, id: "c1", updatedAt: "2026-01-01T00:00:00.000Z")
            try SyncFixtures.insertReminder(
                db, id: "r1", contactID: "c1", remindAt: "2026-02-01T00:00:00.000Z",
                updatedAt: "2026-01-01T00:00:03.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:03.000Z",
                notificationID: "local-notif-1"
            )
        }
        let transport = StubSyncTransport()
        // Same race as pullDoesNotOverwriteALocallyDirtyRow: the reminder is
        // re-edited while its push is in flight, so it is still dirty when
        // the pull tries to apply the server's tombstone and the guarded
        // upsert skips it — the row stays live locally, and its notification
        // must therefore stay scheduled.
        await transport.setOnUpsert { _, _ in
            try database.write { db in
                try db.execute(
                    sql: "UPDATE reminders SET title = 'Edited', is_dirty = 1, dirty_at = ? WHERE id = 'r1'",
                    arguments: ["2026-01-01T00:00:04.000Z"]
                )
            }
        }
        await transport.setServerRows(table: .reminders, rows: [
            serverReminderRow(id: "r1", contactID: "c1", remindAt: "2026-02-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:05.000Z", deletedAt: "2026-01-01T00:00:05.000Z")
        ])
        let engine = makeEngine(database: database, transport: transport)

        let outcome = await engine.syncNow(reason: "test")
        #expect(outcome.pulledReminderTombstoneNotificationIDs == [])

        let deletedAt = try database.read { db in try SyncFixtures.column(db, table: .reminders, id: "r1", column: "deleted_at") }
        #expect(deletedAt == nil)
    }

    @Test func syncStateIsPersistedWithTheActiveUserAndCursor() async throws {
        let database = try AppDatabase.inMemory()
        let transport = StubSyncTransport()
        await transport.setServerRows(table: .contacts, rows: [
            serverContactRow(id: "c1", updatedAt: "2026-01-01T00:00:01.000Z")
        ])
        let engine = makeEngine(database: database, transport: transport)

        _ = await engine.syncNow(reason: "test")

        let state = try SyncStateStore(database: database).read()
        #expect(state.userID == testUserID)
        #expect(state.serverCursor == "2026-01-01T00:00:01.000Z")
        #expect(state.lastSyncAt != nil)
    }

    // MARK: - The trigger/pull ping-pong invariant

    /// Local triggers (`trg_memories_sync_contact_after_insert`, same on
    /// both the RN and Swift schemas) fire on pull-applied writes too — the
    /// SQLite/GRDB engine cannot tell a pull's `INSERT` apart from any other
    /// write. That trigger bumps the parent contact's local `updated_at`
    /// (via `strftime('now')`) but *never* touches `is_dirty`/`dirty_at` —
    /// see `refreshContactInteractionSql` in schema.ts and its Swift twin in
    /// SchemaSQL.swift, neither of which assigns those two columns. So a
    /// contact whose `is_dirty` was 0 before the trigger fired stays 0
    /// after, even though its local `updated_at` no longer matches the
    /// server's.
    ///
    /// This matters for the sync cursor because the cursor is computed
    /// purely from the *server-returned* `updated_at` values captured
    /// before any local write happens (`fetchTableSince`'s `maxUpdatedAt`) —
    /// never from a local column re-read after triggers ran. A second,
    /// identical pull therefore asks the server for `updated_at gt
    /// <cursor>` using the same cursor either way, gets back zero rows
    /// (nothing changed server-side), and the push phase finds zero dirty
    /// rows (the trigger never dirtied anything). Equilibrium.
    @Test func pullingTwiceInARowLeavesNothingDirtyAndPushesNothing() async throws {
        let database = try AppDatabase.inMemory()
        let transport = StubSyncTransport()
        await transport.setServerRows(table: .contacts, rows: [
            serverContactRow(id: "c1", name: "Ada", updatedAt: "2026-01-01T00:00:01.000Z")
        ])
        await transport.setServerRows(table: .memories, rows: [
            serverMemoryRow(id: "m1", contactID: "c1", text: "met for coffee", updatedAt: "2026-01-01T00:00:02.000Z")
        ])
        let engine = makeEngine(database: database, transport: transport)

        let first = await engine.syncNow(reason: "first")
        #expect(first.kind == .succeeded)

        // The trigger fired: the contact's local updated_at no longer
        // equals what the server sent (proving this test actually exercises
        // the trigger interaction, not a no-op schema).
        let contactUpdatedAt = try database.read { db in try SyncFixtures.column(db, table: .contacts, id: "c1", column: "updated_at") }
        #expect(contactUpdatedAt != "2026-01-01T00:00:01.000Z")

        // But nothing is dirty after the first pull.
        try database.read { db in
            let dirtyContacts = try SyncFixtures.dirtyCount(db, table: .contacts)
            let dirtyMemories = try SyncFixtures.dirtyCount(db, table: .memories)
            #expect(dirtyContacts == 0)
            #expect(dirtyMemories == 0)
        }

        let second = await engine.syncNow(reason: "second")
        #expect(second.kind == .succeeded)

        // The second pull, against the same unchanged server dataset,
        // fetched (and applied) nothing, and the second push pushed nothing.
        let secondContactQueries = await transport.pullQueries.filter { $0.table == .contacts }
        // First sync issues exactly one page-request per table (cursor was
        // nil); the second sync issues one more, which must come back empty.
        #expect(secondContactQueries.count == 2)

        let pushedAnything = await transport.upsertCallOrder
        #expect(pushedAnything.isEmpty)

        try database.read { db in
            let dirtyContacts = try SyncFixtures.dirtyCount(db, table: .contacts)
            let dirtyMemories = try SyncFixtures.dirtyCount(db, table: .memories)
            #expect(dirtyContacts == 0)
            #expect(dirtyMemories == 0)
        }

        // The cursor did not regress or get corrupted by the trigger bump.
        let state = try SyncStateStore(database: database).read()
        #expect(state.serverCursor == "2026-01-01T00:00:02.000Z")
    }
}

extension StubSyncTransport {
    func setServerRows(table: SyncTable, rows: [JSONObject]) {
        serverRows[table] = rows
    }
}
