import Foundation
import Testing
@testable import ReloraData
import ReloraCore
import GRDB

@Suite("MemoryRepository")
struct MemoryRepositoryTests {
    private func makeContact(_ database: AppDatabase) throws -> Contact {
        let contactRepo = ContactRepository(database: database)
        let contact = Fixtures.makeContact()
        try contactRepo.upsert(id: contact.id, userID: contact.userID, name: contact.name, createdAt: contact.createdAt)
        return contact
    }

    @Test("upsert marks the row dirty")
    func upsertMarksDirty() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = MemoryRepository(database: database)

        let memory = Fixtures.makeMemory(contactID: contact.id, labels: ["fun", "food"])
        try repo.upsert(memory)

        let loaded = try repo.list(contactID: contact.id).first
        #expect(loaded?.isDirty == true)
        #expect(loaded?.dirtyAt != nil)
        #expect(loaded?.labels == ["fun", "food"])
    }

    @Test("audio_local_uri is preserved when a later upsert omits it")
    func audioLocalURICoalescesOnConflict() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = MemoryRepository(database: database)

        var memory = Fixtures.makeMemory(contactID: contact.id)
        memory.audioLocalURI = "file:///local/recording.m4a"
        try repo.upsert(memory)

        // A later upsert (e.g. a text edit) that does not know about the
        // local file must not clear it.
        memory.text = "Edited text"
        memory.audioLocalURI = nil
        try repo.upsert(memory)

        let loaded = try repo.list(contactID: contact.id).first
        #expect(loaded?.text == "Edited text")
        #expect(loaded?.audioLocalURI == "file:///local/recording.m4a")
    }

    @Test("audio_local_uri is overwritten when a later upsert provides a new value")
    func audioLocalURIOverwritesWhenProvided() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = MemoryRepository(database: database)

        var memory = Fixtures.makeMemory(contactID: contact.id)
        memory.audioLocalURI = "file:///local/first.m4a"
        try repo.upsert(memory)

        memory.audioLocalURI = "file:///local/second.m4a"
        try repo.upsert(memory)

        let loaded = try repo.list(contactID: contact.id).first
        #expect(loaded?.audioLocalURI == "file:///local/second.m4a")
    }

    @Test("list orders active memories by created_at descending and excludes soft-deleted rows")
    func listOrdersByCreatedAtDescending() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = MemoryRepository(database: database)

        let older = Fixtures.makeMemory(contactID: contact.id, text: "Older")
        try repo.upsert(older)

        var newer = Fixtures.makeMemory(contactID: contact.id, text: "Newer")
        newer.createdAt = ReloraTimestamp.from(Date().addingTimeInterval(1))
        newer.updatedAt = newer.createdAt
        try repo.upsert(newer)

        var deleted = Fixtures.makeMemory(contactID: contact.id, text: "Deleted")
        deleted.createdAt = ReloraTimestamp.from(Date().addingTimeInterval(2))
        deleted.updatedAt = deleted.createdAt
        try repo.upsert(deleted)
        _ = try repo.softDelete(itemID: deleted.id, contactID: contact.id, userID: contact.userID)

        let listed = try repo.list(contactID: contact.id)
        #expect(listed.map(\.text) == ["Newer", "Older"])
    }

    @Test("softDelete then restore round-trips text, labels, and transcript")
    func softDeleteThenRestoreRoundTrips() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = MemoryRepository(database: database)

        let memory = Fixtures.makeMemory(contactID: contact.id, labels: ["work"], transcript: "we talked about the project")
        try repo.upsert(memory)

        let deleteResult = try repo.softDelete(itemID: memory.id, contactID: contact.id, userID: contact.userID)
        #expect(deleteResult.deleted)
        #expect(try repo.list(contactID: contact.id).isEmpty)

        let restoreResult = try repo.restore(itemID: memory.id, contactID: contact.id, userID: contact.userID, deletedAt: deleteResult.deletedAt)
        #expect(restoreResult.restored)

        let restored = try repo.list(contactID: contact.id).first
        #expect(restored?.labels == ["work"])
        #expect(restored?.transcript == "we talked about the project")
    }
}
