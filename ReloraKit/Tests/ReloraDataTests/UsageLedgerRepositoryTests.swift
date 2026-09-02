import Testing
@testable import ReloraData
import ReloraCore
import GRDB

@Suite("UsageLedgerRepository")
struct UsageLedgerRepositoryTests {
    @Test("append inserts a new event and returns its id")
    func appendInsertsEvent() throws {
        let database = try Fixtures.makeDatabase()
        let repo = UsageLedgerRepository(database: database)

        let id = try repo.append(userID: "user-1", processedAt: "2026-08-01T00:00:00.000Z", source: "voice_note")

        let listed = try repo.list(userID: "user-1")
        #expect(listed.count == 1)
        #expect(listed.first?.id == id)
        #expect(listed.first?.source == "voice_note")
    }

    @Test("append with an existing id is a silent no-op (INSERT OR IGNORE)")
    func appendIsIdempotentByID() throws {
        let database = try Fixtures.makeDatabase()
        let repo = UsageLedgerRepository(database: database)

        try repo.append(id: "fixed-id", userID: "user-1", processedAt: "2026-08-01T00:00:00.000Z", source: "voice_note")
        try repo.append(id: "fixed-id", userID: "user-1", processedAt: "2026-08-02T00:00:00.000Z", source: "voice_note")

        let listed = try repo.list(userID: "user-1")
        #expect(listed.count == 1)
        // The first write wins; the retried call changes nothing.
        #expect(listed.first?.processedAt == "2026-08-01T00:00:00.000Z")
    }

    @Test("list orders events by processed_at descending")
    func listOrdersDescending() throws {
        let database = try Fixtures.makeDatabase()
        let repo = UsageLedgerRepository(database: database)

        try repo.append(userID: "user-1", processedAt: "2026-08-01T00:00:00.000Z", source: "voice_note")
        try repo.append(userID: "user-1", processedAt: "2026-08-03T00:00:00.000Z", source: "voice_note")
        try repo.append(userID: "user-1", processedAt: "2026-08-02T00:00:00.000Z", source: "voice_note")

        let listed = try repo.list(userID: "user-1")
        #expect(listed.map(\.processedAt) == ["2026-08-03T00:00:00.000Z", "2026-08-02T00:00:00.000Z", "2026-08-01T00:00:00.000Z"])
    }

    @Test("listUnsynced returns only events with no server_synced_at, oldest first")
    func listUnsyncedFiltersAndOrdersAscending() throws {
        let database = try Fixtures.makeDatabase()
        let repo = UsageLedgerRepository(database: database)

        let syncedID = try repo.append(userID: "user-1", processedAt: "2026-08-01T00:00:00.000Z", source: "voice_note")
        try repo.append(userID: "user-1", processedAt: "2026-08-03T00:00:00.000Z", source: "voice_note")
        try repo.append(userID: "user-1", processedAt: "2026-08-02T00:00:00.000Z", source: "voice_note")
        try repo.markServerSynced(ids: [syncedID], syncedAt: "2026-08-05T00:00:00.000Z")

        let unsynced = try repo.listUnsynced(userID: "user-1")
        #expect(unsynced.map(\.processedAt) == ["2026-08-02T00:00:00.000Z", "2026-08-03T00:00:00.000Z"])
    }

    @Test("count is unbounded by default and can be bounded by a half-open [from, to) window")
    func countRespectsWindow() throws {
        let database = try Fixtures.makeDatabase()
        let repo = UsageLedgerRepository(database: database)

        try repo.append(userID: "user-1", processedAt: "2026-07-31T23:59:59.999Z", source: "voice_note")
        try repo.append(userID: "user-1", processedAt: "2026-08-01T00:00:00.000Z", source: "voice_note")
        try repo.append(userID: "user-1", processedAt: "2026-08-15T00:00:00.000Z", source: "voice_note")
        try repo.append(userID: "user-1", processedAt: "2026-09-01T00:00:00.000Z", source: "voice_note")

        #expect(try repo.count(userID: "user-1") == 4)
        #expect(try repo.count(userID: "user-1", from: "2026-08-01T00:00:00.000Z", to: "2026-09-01T00:00:00.000Z") == 2)
    }

    @Test("markServerSynced sets server_synced_at only on the given ids")
    func markServerSyncedOnlyAffectsGivenIDs() throws {
        let database = try Fixtures.makeDatabase()
        let repo = UsageLedgerRepository(database: database)

        let idA = try repo.append(userID: "user-1", processedAt: "2026-08-01T00:00:00.000Z", source: "voice_note")
        let idB = try repo.append(userID: "user-1", processedAt: "2026-08-02T00:00:00.000Z", source: "voice_note")

        try repo.markServerSynced(ids: [idA], syncedAt: "2026-08-10T00:00:00.000Z")

        let listed = try repo.list(userID: "user-1")
        let synced = listed.first { $0.id == idA }
        let untouched = listed.first { $0.id == idB }
        #expect(synced?.serverSyncedAt == "2026-08-10T00:00:00.000Z")
        #expect(untouched?.serverSyncedAt == nil)
    }
}
