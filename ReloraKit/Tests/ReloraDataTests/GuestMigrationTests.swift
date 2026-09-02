import Foundation
import Testing
import GRDB
@testable import ReloraData
import ReloraCore

private let fromUserID = Fixtures.defaultUserID
private let toUserID = "user-2"

/// Seeds one contact with a key thing, memory, and reminder (linked to the
/// memory), plus a usage event and a `sync_state` pointed at `fromUserID` —
/// the fixture every test in this file migrates away from.
private func seedOwnedData(_ database: AppDatabase) throws -> (contactID: String, memoryID: String) {
    let contact = Fixtures.makeContact(userID: fromUserID)
    try ContactRepository(database: database).upsert(
        id: contact.id, userID: contact.userID, name: contact.name
    )

    let memory = Fixtures.makeMemory(contactID: contact.id, userID: fromUserID)
    try MemoryRepository(database: database).upsert(memory)

    let keyThing = Fixtures.makeKeyThing(contactID: contact.id, userID: fromUserID)
    try KeyThingRepository(database: database).upsert(keyThing)

    let reminder = Fixtures.makeReminder(contactID: contact.id, userID: fromUserID, memoryID: memory.id)
    try ReminderRepository(database: database).upsert(reminder)

    try UsageLedgerRepository(database: database).append(userID: fromUserID, processedAt: ReloraTimestamp.now(), source: "test")

    try SyncStateStore(database: database).update(userID: .some(fromUserID), serverCursor: .some("cursor-1"), lastSyncAt: .some(ReloraTimestamp.now()))

    return (contact.id, memory.id)
}

private func ownerIDs(_ database: AppDatabase, table: String) throws -> [String] {
    try database.read { db in
        try String.fetchAll(db, sql: "SELECT user_id FROM \(table)")
    }
}

// MARK: - Full migration

@Test func fullMigrationReassignsAllContentTablesAndMarksDirty() throws {
    let database = try Fixtures.makeDatabase()
    _ = try seedOwnedData(database)
    let migration = GuestMigration(database: database)

    try migration.migrateOwnership(fromUserID: fromUserID, toUserID: toUserID)

    for table in ["contacts", "key_things", "memories", "reminders"] {
        #expect(try ownerIDs(database, table: table) == [toUserID], "\(table) should be reassigned")
        let dirtyRows = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT is_dirty, dirty_at FROM \(table)")
        }
        for row in dirtyRows {
            let isDirty: Int = row["is_dirty"]
            let dirtyAt: String? = row["dirty_at"]
            #expect(isDirty == 1)
            #expect(dirtyAt != nil)
        }
    }
}

@Test func usageEventIsReownedWithServerSyncedAtCleared() throws {
    let database = try Fixtures.makeDatabase()
    _ = try seedOwnedData(database)
    let migration = GuestMigration(database: database)

    try migration.migrateOwnership(fromUserID: fromUserID, toUserID: toUserID)

    let row = try #require(try database.read { db in
        try Row.fetchOne(db, sql: "SELECT user_id, server_synced_at FROM voice_note_usage_events")
    })
    let userID: String = row["user_id"]
    let serverSyncedAt: String? = row["server_synced_at"]
    #expect(userID == toUserID)
    #expect(serverSyncedAt == nil)
}

@Test func syncStateIsFullyResetAfterMigration() throws {
    let database = try Fixtures.makeDatabase()
    _ = try seedOwnedData(database)
    let migration = GuestMigration(database: database)

    try migration.migrateOwnership(fromUserID: fromUserID, toUserID: toUserID)

    let state = try SyncStateStore(database: database).read()
    #expect(state.userID == nil)
    #expect(state.serverCursor == nil)
    #expect(state.lastSyncAt == nil)
}

@Test func foreignKeyIntegrityHoldsAfterMigration() throws {
    let database = try Fixtures.makeDatabase()
    _ = try seedOwnedData(database)
    let migration = GuestMigration(database: database)

    try migration.migrateOwnership(fromUserID: fromUserID, toUserID: toUserID)

    let violations = try database.read { db in
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
    }
    #expect(violations.isEmpty)

    // Foreign key enforcement itself must be back on for the connection,
    // not just unviolated at this instant.
    let enabled = try database.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") }
    #expect(enabled == 1)
}

// MARK: - Idempotency

@Test func migrateOwnershipIsIdempotentOnRetry() throws {
    let database = try Fixtures.makeDatabase()
    _ = try seedOwnedData(database)
    let migration = GuestMigration(database: database)

    try migration.migrateOwnership(fromUserID: fromUserID, toUserID: toUserID)
    // A second call finds nothing left matching `WHERE user_id = fromUserID` —
    // must be a silent no-op, not an error or a duplicate write.
    try migration.migrateOwnership(fromUserID: fromUserID, toUserID: toUserID)

    for table in ["contacts", "key_things", "memories", "reminders"] {
        #expect(try ownerIDs(database, table: table) == [toUserID])
    }
}

@Test func migrateOwnershipSkipsWhenSameUserOrEmpty() throws {
    let database = try Fixtures.makeDatabase()
    _ = try seedOwnedData(database)
    let migration = GuestMigration(database: database)

    try migration.migrateOwnership(fromUserID: fromUserID, toUserID: fromUserID)
    try migration.migrateOwnership(fromUserID: "", toUserID: toUserID)

    #expect(try ownerIDs(database, table: "contacts") == [fromUserID])
}

// MARK: - Resume from a marker (simulated crash)

@Test func resumeCompletesAPartialRewriteLeftByAnEarlierSession() async throws {
    let database = try Fixtures.makeDatabase()
    _ = try seedOwnedData(database)
    let migration = GuestMigration(database: database)

    // Simulate a process interrupted mid-migration: the marker was written
    // (as `runMigration` always does first) and only `contacts` made it
    // through the rewrite before the crash.
    try migration.writePending(GuestMigration.PendingMigration(
        fromUserID: fromUserID, toUserID: toUserID, lastAttemptAt: ReloraTimestamp.now()
    ))
    // `writeWithoutTransaction`, like `migrateOwnership` itself: SQLite
    // ignores `PRAGMA foreign_keys` inside a transaction, and the child
    // tables' composite (contact_id, user_id) keys reject a contacts-only
    // rewrite while enforcement is on.
    try database.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA foreign_keys = OFF")
        defer { try? db.execute(sql: "PRAGMA foreign_keys = ON") }
        try db.execute(sql: "UPDATE contacts SET user_id = ? WHERE user_id = ?", arguments: [toUserID, fromUserID])
    }
    #expect(try migration.hasPending())

    let result = await migration.resumePendingMigrationIfAny(toUserID: toUserID, identityKind: .account, source: "boot")

    #expect(result.outcome == .succeeded)
    #expect(result.fromUserID == fromUserID)
    #expect(result.toUserID == toUserID)
    #expect(try migration.hasPending() == false)
    for table in ["contacts", "key_things", "memories", "reminders"] {
        #expect(try ownerIDs(database, table: table) == [toUserID], "\(table) should have caught up")
    }
}

@Test func resumeSkipsWhenNoIdentityCanClaimTheRows() async throws {
    let database = try Fixtures.makeDatabase()
    _ = try seedOwnedData(database)
    let migration = GuestMigration(database: database)
    try migration.writePending(GuestMigration.PendingMigration(
        fromUserID: fromUserID, toUserID: "some-other-account", lastAttemptAt: ReloraTimestamp.now()
    ))

    let signedOut = await migration.resumePendingMigrationIfAny(toUserID: nil, identityKind: .none, source: "boot")
    #expect(signedOut.outcome == .skipped)
    #expect(signedOut.toUserID == nil)

    let anonymous = await migration.resumePendingMigrationIfAny(toUserID: "guest-2", identityKind: .anonymous, source: "boot")
    #expect(anonymous.outcome == .skipped)

    // Neither attempt may touch the marker or the rows.
    #expect(try migration.hasPending())
    #expect(try ownerIDs(database, table: "contacts") == [fromUserID])
}

@Test func resumeClearsAStaleMarkerAlreadySatisfiedByTheCurrentAccount() async throws {
    let database = try Fixtures.makeDatabase()
    let migration = GuestMigration(database: database)
    // The marker's source id *is* the account now signed in — the rows it
    // describes already landed. Mirrors "drops a stale marker whose rows
    // already belong to the active account" in ownershipMigration.test.ts.
    try migration.writePending(GuestMigration.PendingMigration(
        fromUserID: toUserID, toUserID: toUserID, lastAttemptAt: ReloraTimestamp.now()
    ))

    let result = await migration.resumePendingMigrationIfAny(toUserID: toUserID, identityKind: .account, source: "boot")

    #expect(result.outcome == .skipped)
    #expect(try migration.hasPending() == false)
}

@Test func resumeSkipsWhenNoMarkerExists() async throws {
    let database = try Fixtures.makeDatabase()
    let migration = GuestMigration(database: database)

    let result = await migration.resumePendingMigrationIfAny(toUserID: toUserID, identityKind: .account, source: "boot")

    #expect(result.outcome == .skipped)
    #expect(result.fromUserID == nil)
    #expect(result.toUserID == nil)
}

// MARK: - Retry / deferred outcome

@Test func runMigrationClearsTheMarkerOnSuccess() async throws {
    let database = try Fixtures.makeDatabase()
    _ = try seedOwnedData(database)
    let migration = GuestMigration(database: database)

    let outcome = await migration.runMigration(fromUserID: fromUserID, toUserID: toUserID, source: "sign-in")

    #expect(outcome == .succeeded)
    #expect(try migration.hasPending() == false)
}

@Test func runMigrationDefersAndRecordsFailedAttemptsWhenTheRewriteKeepsFailing() async throws {
    let database = try Fixtures.makeDatabase()
    _ = try seedOwnedData(database)
    // Break the rewrite deterministically: every attempt's `UPDATE sync_state`
    // now fails against a table that no longer exists.
    try database.write { db in try db.execute(sql: "DROP TABLE sync_state") }
    let migration = GuestMigration(database: database)

    let outcome = await migration.runMigration(
        fromUserID: fromUserID,
        toUserID: toUserID,
        source: "sign-in",
        delays: [.milliseconds(1), .milliseconds(1)]
    )

    #expect(outcome == .deferred)
    let pending = try #require(try migration.readPending())
    #expect(pending.fromUserID == fromUserID)
    #expect(pending.toUserID == toUserID)
    #expect(pending.failedAttempts == 1)
    #expect(pending.lastError != nil)

    // Foreign keys must still be restored even though the rewrite threw.
    let enabled = try database.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") }
    #expect(enabled == 1)
}

@Test func runMigrationSkipsSameUserOrEmptyIDsWithoutTouchingTheMarker() async throws {
    let database = try Fixtures.makeDatabase()
    let migration = GuestMigration(database: database)

    let outcome = await migration.runMigration(fromUserID: fromUserID, toUserID: fromUserID, source: "test")

    #expect(outcome == .skipped)
    #expect(try migration.hasPending() == false)
}

// MARK: - clearAllLocalData

@Test func clearAllLocalDataWipesEveryTableAndFlagsTheSearchIndexForRebuild() throws {
    let database = try Fixtures.makeDatabase()
    _ = try seedOwnedData(database)
    let settings = AppSettingsStore(database: database)
    try settings.setRawValue(.localAnonymousUserID, "local-guest-9")
    // Give the FTS table a row to wipe, and clear the schema's initial
    // needs-rebuild flag so the assertion below proves clearAllLocalData
    // set it rather than inheriting it.
    try database.write { db in
        try db.execute(sql: "INSERT INTO contact_search (contact_id, name) VALUES ('c-1', 'Priya')")
        try db.execute(sql: "UPDATE search_index_meta SET value = '0' WHERE key = 'contact_search_needs_rebuild'")
    }
    let migration = GuestMigration(database: database)

    try migration.clearAllLocalData()

    for table in ["contacts", "key_things", "memories", "reminders", "voice_note_usage_events", "app_settings", "contact_search"] {
        let count = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")
        }
        #expect(count == 0, "\(table) should be empty")
    }

    // app_settings going with it is deliberate: RN's clearLocalData wipes
    // onboarding state and the stored guest id too (account deletion is a
    // full reset).
    #expect(try settings.getRawValue(.localAnonymousUserID) == nil)

    let state = try SyncStateStore(database: database).read()
    #expect(state.userID == nil)
    #expect(state.serverCursor == nil)
    #expect(state.lastSyncAt == nil)

    let rebuildFlag = try database.read { db in
        try String.fetchOne(db, sql: "SELECT value FROM search_index_meta WHERE key = 'contact_search_needs_rebuild'")
    }
    #expect(rebuildFlag == "1")
}

// MARK: - canClaimStrandedRows

@Test func canClaimStrandedRowsOnlyForAccountIdentity() {
    #expect(GuestMigration.canClaimStrandedRows(.account))
    #expect(GuestMigration.canClaimStrandedRows(.anonymous) == false)
    #expect(GuestMigration.canClaimStrandedRows(.none) == false)
}

// MARK: - Marker round-trip

@Test func pendingMarkerRoundTripsThroughRawJSON() throws {
    let database = try Fixtures.makeDatabase()
    let migration = GuestMigration(database: database)
    let marker = GuestMigration.PendingMigration(
        fromUserID: fromUserID, toUserID: toUserID, failedAttempts: 2, lastAttemptAt: "2026-08-31T00:00:00.000Z", lastError: "boom"
    )

    try migration.writePending(marker)
    let readBack = try migration.readPending()

    #expect(readBack == marker)

    // The on-disk shape matches RN's JSON field names exactly.
    let raw = try #require(try AppSettingsStore(database: database).getRawValue(.pendingOwnershipMigration))
    #expect(raw.contains("\"fromUserId\""))
    #expect(raw.contains("\"toUserId\""))

    try migration.writePending(nil)
    #expect(try migration.readPending() == nil)
}
