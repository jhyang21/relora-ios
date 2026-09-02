import Foundation
import GRDB
import Testing
import ReloraCore
import ReloraData
@testable import ReloraSync

@Suite struct SyncEnginePushTests {

    private func makeEngine(
        database: AppDatabase,
        transport: StubSyncTransport,
        pushBatchSize: Int = 500,
        maxPushBatches: Int = 20,
        userID: String? = testUserID
    ) -> SyncEngine {
        SyncEngine(
            database: database,
            transport: transport,
            userIDProvider: { userID },
            isOnline: { true },
            pushBatchSize: pushBatchSize,
            maxPushBatches: maxPushBatches,
            pullPageSize: 500,
            writeDebounceNanoseconds: 0,
            retryDelaysMilliseconds: []
        )
    }

    @Test func pushOrdersTablesParentFirst() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            try SyncFixtures.insertContact(db, id: "c1", updatedAt: "2026-01-01T00:00:00.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:00.000Z")
            try SyncFixtures.insertMemory(db, id: "m1", contactID: "c1", updatedAt: "2026-01-01T00:00:00.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:00.000Z")
            try SyncFixtures.insertReminder(db, id: "r1", contactID: "c1", remindAt: "2026-02-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:00.000Z")
        }
        let transport = StubSyncTransport()
        let engine = makeEngine(database: database, transport: transport)

        let outcome = await engine.syncNow(reason: "test")
        #expect(outcome.kind == .succeeded)

        let order = await transport.upsertCallOrder
        #expect(order == [.contacts, .memories, .reminders])
    }

    @Test func pushOrdersDirtyRowsByDirtyAtThenUpdatedAt() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            try SyncFixtures.insertContact(db, id: "later", name: "Later", updatedAt: "2026-01-01T00:00:02.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:02.000Z")
            try SyncFixtures.insertContact(db, id: "earlier", name: "Earlier", updatedAt: "2026-01-01T00:00:01.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:01.000Z")
        }
        let transport = StubSyncTransport()
        let engine = makeEngine(database: database, transport: transport)

        _ = await engine.syncNow(reason: "test")

        let batches = await transport.upsertedBatches[.contacts]
        let ids = batches?.first?.compactMap { row -> String? in
            if case .string(let id)? = row["id"] { return id }
            return nil
        }
        #expect(ids == ["earlier", "later"])
    }

    @Test func pushClearsDirtyFlagOnlyWhenDirtyAtStillMatchesTheSnapshot() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            try SyncFixtures.insertContact(db, id: "c1", updatedAt: "2026-01-01T00:00:00.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:00.000Z")
        }
        let transport = StubSyncTransport()
        // Simulate a concurrent local edit landing between the push
        // snapshot read and the guarded flag-clear: the row is re-dirtied
        // with a NEW dirty_at while the upsert is "in flight".
        await transport.setOnUpsert { _, _ in
            try database.write { db in
                try db.execute(
                    sql: "UPDATE contacts SET name = 'Edited', is_dirty = 1, dirty_at = ? WHERE id = 'c1'",
                    arguments: ["2026-01-01T00:00:05.000Z"]
                )
            }
        }
        let engine = makeEngine(database: database, transport: transport)

        _ = await engine.syncNow(reason: "test")

        let stillDirty = try database.read { db in try SyncFixtures.isDirty(db, table: .contacts, id: "c1") }
        let dirtyAt = try database.read { db in try SyncFixtures.column(db, table: .contacts, id: "c1", column: "dirty_at") }
        #expect(stillDirty)
        #expect(dirtyAt == "2026-01-01T00:00:05.000Z")
    }

    @Test func pushStopsAtMaxPushBatchesLeavingTheRemainderDirty() async throws {
        let database = try AppDatabase.inMemory()
        // pushBatchSize=2, maxPushBatches=2 -> at most 4 rows can be pushed
        // in one sync; seed 5 so one must remain dirty afterward.
        try database.write { db in
            for index in 0..<5 {
                let stamp = "2026-01-01T00:00:0\(index).000Z"
                try SyncFixtures.insertContact(db, id: "c\(index)", updatedAt: stamp, isDirty: true, dirtyAt: stamp)
            }
        }
        let transport = StubSyncTransport()
        let engine = makeEngine(database: database, transport: transport, pushBatchSize: 2, maxPushBatches: 2)

        let outcome = await engine.syncNow(reason: "test")
        #expect(outcome.kind == .succeeded) // hitting the ceiling is not itself a failure

        let remainingDirty = try database.read { db in try SyncFixtures.dirtyCount(db, table: .contacts) }
        #expect(remainingDirty == 1)

        let pushedBatchCount = await transport.upsertedBatches[.contacts]?.count
        #expect(pushedBatchCount == 2)
    }

    @Test func pushSendsOnlyDirtyRowsForTheActiveUser() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            try SyncFixtures.insertContact(db, id: "mine-dirty", userID: testUserID, updatedAt: "2026-01-01T00:00:00.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:00.000Z")
            try SyncFixtures.insertContact(db, id: "mine-clean", userID: testUserID, updatedAt: "2026-01-01T00:00:00.000Z", isDirty: false)
            try SyncFixtures.insertContact(db, id: "other-user-dirty", userID: "someone-else", updatedAt: "2026-01-01T00:00:00.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:00.000Z")
        }
        let transport = StubSyncTransport()
        let engine = makeEngine(database: database, transport: transport)

        _ = await engine.syncNow(reason: "test")

        let pushedIDs = await transport.upsertedBatches[.contacts]?.flatMap { batch in
            batch.compactMap { row -> String? in
                if case .string(let id)? = row["id"] { return id }
                return nil
            }
        }
        #expect(pushedIDs == ["mine-dirty"])
    }

    @Test func aTableFailureFailsTheWholeSync() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            try SyncFixtures.insertContact(db, id: "c1", updatedAt: "2026-01-01T00:00:00.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:00.000Z")
        }
        let transport = StubSyncTransport()
        await transport.queueUpsertError(table: .contacts, error: BackendError(code: "SOME_ERROR", message: "boom", httpStatus: 500))
        let engine = makeEngine(database: database, transport: transport)

        let outcome = await engine.syncNow(reason: "test")
        guard case .failed(let failure) = outcome.kind else {
            Issue.record("expected a failed outcome")
            return
        }
        guard case .backend(let backendError) = failure else {
            Issue.record("expected a .backend failure, got \(failure)")
            return
        }
        #expect(backendError.code == "SOME_ERROR")

        // The row that failed to push must stay dirty.
        let stillDirty = try database.read { db in try SyncFixtures.isDirty(db, table: .contacts, id: "c1") }
        #expect(stillDirty)
    }

    @Test func authRequiredIsMappedDistinctlyInTheOutcome() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            try SyncFixtures.insertContact(db, id: "c1", updatedAt: "2026-01-01T00:00:00.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:00.000Z")
        }
        let transport = StubSyncTransport()
        await transport.queueUpsertError(table: .contacts, error: BackendError(code: BackendError.authRequired, message: "no session", httpStatus: 401))
        let engine = makeEngine(database: database, transport: transport)

        let outcome = await engine.syncNow(reason: "test")
        guard case .failed(.authRequired) = outcome.kind else {
            Issue.record("expected an authRequired failure, got \(outcome.kind)")
            return
        }
    }
}

extension StubSyncTransport {
    func setOnUpsert(_ hook: @escaping @Sendable (SyncTable, [JSONObject]) async throws -> Void) {
        onUpsert = hook
    }

    func queueUpsertError(table: SyncTable, error: BackendError) {
        upsertErrorQueue[table, default: []].append(error)
    }
}
