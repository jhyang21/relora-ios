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

    // MARK: - get / edit

    @Test("get returns the full row for an id, and nil for one that is not there")
    func getReturnsRow() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = MemoryRepository(database: database)

        let memory = Fixtures.makeMemory(contactID: contact.id, text: "Coffee at Ape", transcript: "we talked")
        try repo.upsert(memory)

        let loaded = try repo.get(id: memory.id)
        #expect(loaded?.text == "Coffee at Ape")
        #expect(loaded?.transcript == "we talked")
        #expect(try repo.get(id: "no-such-memory") == nil)
    }

    @Test("edit rewrites text and created_at and re-dirties the row")
    func editRewritesTextAndDate() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = MemoryRepository(database: database)

        let memory = Fixtures.makeMemory(contactID: contact.id, text: "Original")
        try repo.upsert(memory)
        try clearDirtyFlags(database, id: memory.id)

        let newCreatedAt = ReloraTimestamp.from(Date().addingTimeInterval(-86_400))
        try repo.edit(id: memory.id, text: "Corrected", createdAt: newCreatedAt, userID: contact.userID)

        let loaded = try repo.get(id: memory.id)
        #expect(loaded?.text == "Corrected")
        #expect(loaded?.createdAt == newCreatedAt)
        #expect(loaded?.isDirty == true)
        #expect(loaded?.dirtyAt != nil)
        // `updated_at` and `dirty_at` are the same instant, the way every
        // other local write in this module stamps them — `clearDirtyFlags`
        // matches on `dirty_at` exactly, so it has to be a value the write
        // actually stored.
        #expect(loaded?.updatedAt == loaded?.dirtyAt)
    }

    /// Correcting the wording of a note must not throw away the recording it
    /// came from, or the transcript that recording produced.
    @Test("edit leaves transcript, labels and audio columns alone")
    func editPreservesTranscriptAndAudio() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = MemoryRepository(database: database)

        var memory = Fixtures.makeMemory(
            contactID: contact.id,
            text: "Original",
            labels: ["work"],
            transcript: "the whole conversation"
        )
        memory.audioLocalURI = "recording.m4a"
        memory.audioURL = "https://example.com/recording.m4a"
        try repo.upsert(memory)

        try repo.edit(id: memory.id, text: "Corrected", createdAt: memory.createdAt, userID: contact.userID)

        let loaded = try repo.get(id: memory.id)
        #expect(loaded?.transcript == "the whole conversation")
        #expect(loaded?.audioLocalURI == "recording.m4a")
        #expect(loaded?.audioURL == "https://example.com/recording.m4a")
        #expect(loaded?.labels == ["work"])
    }

    @Test("edit does nothing to a soft-deleted row")
    func editSkipsTombstonedRow() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = MemoryRepository(database: database)

        let memory = Fixtures.makeMemory(contactID: contact.id, text: "Original")
        try repo.upsert(memory)
        _ = try repo.softDelete(itemID: memory.id, contactID: contact.id, userID: contact.userID)

        try repo.edit(id: memory.id, text: "Corrected", createdAt: memory.createdAt, userID: contact.userID)

        #expect(try repo.get(id: memory.id)?.text == "Original")
    }

    @Test("edit does nothing under the wrong user id")
    func editSkipsAnotherUsersRow() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = MemoryRepository(database: database)

        let memory = Fixtures.makeMemory(contactID: contact.id, text: "Original")
        try repo.upsert(memory)

        try repo.edit(id: memory.id, text: "Corrected", createdAt: memory.createdAt, userID: "someone-else")

        #expect(try repo.get(id: memory.id)?.text == "Original")
    }

    /// An edited date re-orders the timeline, which is the whole reason the
    /// date is editable.
    @Test("list order follows an edited created_at")
    func listOrderFollowsEditedDate() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = MemoryRepository(database: database)

        let older = Fixtures.makeMemory(contactID: contact.id, text: "Older")
        try repo.upsert(older)

        var newer = Fixtures.makeMemory(contactID: contact.id, text: "Newer")
        newer.createdAt = ReloraTimestamp.from(Date().addingTimeInterval(1))
        newer.updatedAt = newer.createdAt
        try repo.upsert(newer)

        #expect(try repo.list(contactID: contact.id).map(\.text) == ["Newer", "Older"])

        try repo.edit(
            id: older.id,
            text: "Older",
            createdAt: ReloraTimestamp.from(Date().addingTimeInterval(60)),
            userID: contact.userID
        )

        #expect(try repo.list(contactID: contact.id).map(\.text) == ["Older", "Newer"])
    }

    /// Mimics what `SyncEngine.clearDirtyFlags` does after a successful push,
    /// so the next assertion is about this write and not the one before it.
    private func clearDirtyFlags(_ database: AppDatabase, id: String) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE memories SET is_dirty = 0, dirty_at = NULL WHERE id = ?",
                arguments: [id]
            )
        }
    }

    @Test("liveAudioLocalURIs returns the value a live memory points at")
    func liveAudioLocalURIsIncludesLiveRows() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = MemoryRepository(database: database)

        var memory = Fixtures.makeMemory(contactID: contact.id)
        memory.audioLocalURI = "kept.m4a"
        try repo.upsert(memory)

        #expect(try repo.liveAudioLocalURIs() == Set(["kept.m4a"]))
    }

    @Test("liveAudioLocalURIs skips a tombstoned memory")
    func liveAudioLocalURIsSkipsTombstonedRows() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = MemoryRepository(database: database)

        var memory = Fixtures.makeMemory(contactID: contact.id)
        memory.audioLocalURI = "orphaned.m4a"
        try repo.upsert(memory)
        _ = try repo.softDelete(itemID: memory.id, contactID: contact.id, userID: contact.userID)

        #expect(try repo.liveAudioLocalURIs().isEmpty)
    }

    @Test("liveAudioLocalURIs skips null and blank values")
    func liveAudioLocalURIsSkipsNullAndBlankValues() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = MemoryRepository(database: database)

        try repo.upsert(Fixtures.makeMemory(contactID: contact.id, text: "Typed, no audio"))

        var blank = Fixtures.makeMemory(contactID: contact.id, text: "Blank audio value")
        blank.audioLocalURI = "   "
        try repo.upsert(blank)

        var real = Fixtures.makeMemory(contactID: contact.id, text: "Real audio")
        real.audioLocalURI = "real.m4a"
        try repo.upsert(real)

        #expect(try repo.liveAudioLocalURIs() == Set(["real.m4a"]))
    }

    @Test("liveAudioLocalURIs counts every user's rows")
    func liveAudioLocalURIsCountsEveryUser() throws {
        let database = try Fixtures.makeDatabase()
        let contactRepo = ContactRepository(database: database)
        let repo = MemoryRepository(database: database)

        let guest = Fixtures.makeContact(userID: "guest-1")
        try contactRepo.upsert(id: guest.id, userID: guest.userID, name: guest.name, createdAt: guest.createdAt)
        let account = Fixtures.makeContact(userID: "account-1")
        try contactRepo.upsert(id: account.id, userID: account.userID, name: account.name, createdAt: account.createdAt)

        var guestMemory = Fixtures.makeMemory(contactID: guest.id, userID: guest.userID)
        guestMemory.audioLocalURI = "guest.m4a"
        try repo.upsert(guestMemory)

        var accountMemory = Fixtures.makeMemory(contactID: account.id, userID: account.userID)
        accountMemory.audioLocalURI = "account.m4a"
        try repo.upsert(accountMemory)

        #expect(try repo.liveAudioLocalURIs() == Set(["guest.m4a", "account.m4a"]))
    }
}
