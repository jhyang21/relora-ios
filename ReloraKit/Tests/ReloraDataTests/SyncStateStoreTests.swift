import Testing
@testable import ReloraData
import ReloraCore
import GRDB

@Suite("SyncStateStore")
struct SyncStateStoreTests {
    @Test("read returns the seeded singleton row with every field nil")
    func readReturnsSeededDefaults() throws {
        let database = try Fixtures.makeDatabase()
        let store = SyncStateStore(database: database)
        let state = try store.read()
        #expect(state == SyncState(userID: nil, serverCursor: nil, lastSyncAt: nil))
    }

    @Test("update writes only the fields explicitly passed, leaving omitted fields untouched")
    func updateWritesOnlyExplicitFields() throws {
        let database = try Fixtures.makeDatabase()
        let store = SyncStateStore(database: database)

        try store.update(userID: .some("user-1"), serverCursor: .some("cursor-1"))
        var state = try store.read()
        #expect(state.userID == "user-1")
        #expect(state.serverCursor == "cursor-1")
        #expect(state.lastSyncAt == nil)

        // Omitting userID/serverCursor (the default `.none`) must not clear them.
        try store.update(lastSyncAt: .some("2026-08-31T00:00:00.000Z"))
        state = try store.read()
        #expect(state.userID == "user-1")
        #expect(state.serverCursor == "cursor-1")
        #expect(state.lastSyncAt == "2026-08-31T00:00:00.000Z")
    }

    @Test("update with .some(nil) explicitly clears a field")
    func updateWithExplicitNilClearsField() throws {
        let database = try Fixtures.makeDatabase()
        let store = SyncStateStore(database: database)

        try store.update(userID: .some("user-1"))
        try store.update(userID: .some(nil))

        #expect(try store.read().userID == nil)
    }

    @Test("update with no arguments is a no-op")
    func updateWithNoArgumentsIsNoOp() throws {
        let database = try Fixtures.makeDatabase()
        let store = SyncStateStore(database: database)
        try store.update(userID: .some("user-1"), serverCursor: .some("cursor-1"), lastSyncAt: .some("2026-08-31T00:00:00.000Z"))

        try store.update()

        let state = try store.read()
        #expect(state.userID == "user-1")
        #expect(state.serverCursor == "cursor-1")
        #expect(state.lastSyncAt == "2026-08-31T00:00:00.000Z")
    }

    @Test("reset clears every field back to nil")
    func resetClearsEveryField() throws {
        let database = try Fixtures.makeDatabase()
        let store = SyncStateStore(database: database)
        try store.update(userID: .some("user-1"), serverCursor: .some("cursor-1"), lastSyncAt: .some("2026-08-31T00:00:00.000Z"))

        try store.reset()

        #expect(try store.read() == SyncState())
    }
}
