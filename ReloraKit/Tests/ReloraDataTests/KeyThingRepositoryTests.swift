import Foundation
import Testing
@testable import ReloraData
import ReloraCore
import GRDB

@Suite("KeyThingRepository")
struct KeyThingRepositoryTests {
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
        let repo = KeyThingRepository(database: database)

        let keyThing = Fixtures.makeKeyThing(contactID: contact.id, text: "Vegetarian")
        try repo.upsert(keyThing)

        let loaded = try repo.list(contactID: contact.id).first
        #expect(loaded?.text == "Vegetarian")
        #expect(loaded?.isDirty == true)
        #expect(loaded?.dirtyAt != nil)
    }

    @Test("list orders active key things by updated_at descending and excludes soft-deleted rows")
    func listOrdersByUpdatedAtDescending() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = KeyThingRepository(database: database)

        let older = Fixtures.makeKeyThing(contactID: contact.id, text: "Older")
        try repo.upsert(older)

        var newer = Fixtures.makeKeyThing(contactID: contact.id, text: "Newer")
        newer.updatedAt = ReloraTimestamp.from(Date().addingTimeInterval(1))
        newer.createdAt = newer.updatedAt
        try repo.upsert(newer)

        var deleted = Fixtures.makeKeyThing(contactID: contact.id, text: "Deleted")
        deleted.updatedAt = ReloraTimestamp.from(Date().addingTimeInterval(2))
        deleted.createdAt = deleted.updatedAt
        try repo.upsert(deleted)
        _ = try repo.softDelete(itemID: deleted.id, contactID: contact.id, userID: contact.userID)

        let listed = try repo.list(contactID: contact.id)
        #expect(listed.map(\.text) == ["Newer", "Older"])
    }

    @Test("re-upserting an existing key thing bumps updated_at and re-dirties it")
    func upsertOnExistingRowUpdatesAndDirties() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = KeyThingRepository(database: database)

        var keyThing = Fixtures.makeKeyThing(contactID: contact.id, text: "First")
        try repo.upsert(keyThing)
        let firstUpdatedAt = try repo.list(contactID: contact.id).first?.updatedAt

        keyThing.text = "Revised"
        keyThing.updatedAt = ReloraTimestamp.from(Date().addingTimeInterval(1))
        try repo.upsert(keyThing)

        let loaded = try repo.list(contactID: contact.id).first
        #expect(loaded?.text == "Revised")
        #expect(loaded?.updatedAt != firstUpdatedAt)
        #expect(loaded?.isDirty == true)
    }

    // MARK: - get / edit

    @Test("get returns the full row for an id, and nil for one that is not there")
    func getReturnsRow() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = KeyThingRepository(database: database)

        let keyThing = Fixtures.makeKeyThing(contactID: contact.id, text: "Drinks oat milk")
        try repo.upsert(keyThing)

        #expect(try repo.get(id: keyThing.id)?.text == "Drinks oat milk")
        #expect(try repo.get(id: "no-such-key-thing") == nil)
    }

    @Test("edit rewrites the text and re-dirties the row")
    func editRewritesText() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = KeyThingRepository(database: database)

        let keyThing = Fixtures.makeKeyThing(contactID: contact.id, text: "Drinks oat milk")
        try repo.upsert(keyThing)
        try database.write { db in
            try db.execute(
                sql: "UPDATE key_things SET is_dirty = 0, dirty_at = NULL WHERE id = ?",
                arguments: [keyThing.id]
            )
        }

        try repo.edit(id: keyThing.id, text: "Drinks soy milk", userID: contact.userID)

        let loaded = try repo.get(id: keyThing.id)
        #expect(loaded?.text == "Drinks soy milk")
        #expect(loaded?.isDirty == true)
        #expect(loaded?.updatedAt == loaded?.dirtyAt)
        // The moment it was first noted does not move when the fact is
        // corrected — only `updated_at` does.
        #expect(loaded?.createdAt == keyThing.createdAt)
    }

    @Test("edit does nothing to a soft-deleted row or under the wrong user id")
    func editSkipsTombstonedAndForeignRows() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = KeyThingRepository(database: database)

        let mine = Fixtures.makeKeyThing(contactID: contact.id, text: "Mine")
        try repo.upsert(mine)
        try repo.edit(id: mine.id, text: "Rewritten", userID: "someone-else")
        #expect(try repo.get(id: mine.id)?.text == "Mine")

        let deleted = Fixtures.makeKeyThing(contactID: contact.id, text: "Deleted")
        try repo.upsert(deleted)
        _ = try repo.softDelete(itemID: deleted.id, contactID: contact.id, userID: contact.userID)
        try repo.edit(id: deleted.id, text: "Rewritten", userID: contact.userID)
        #expect(try repo.get(id: deleted.id)?.text == "Deleted")
    }

    @Test("softDelete then restore brings the row back with its original text")
    func softDeleteThenRestore() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = KeyThingRepository(database: database)

        let keyThing = Fixtures.makeKeyThing(contactID: contact.id, text: "Allergic to peanuts")
        try repo.upsert(keyThing)

        let deleteResult = try repo.softDelete(itemID: keyThing.id, contactID: contact.id, userID: contact.userID)
        #expect(deleteResult.deleted)
        #expect(try repo.list(contactID: contact.id).isEmpty)

        let restoreResult = try repo.restore(itemID: keyThing.id, contactID: contact.id, userID: contact.userID, deletedAt: deleteResult.deletedAt)
        #expect(restoreResult.restored)
        #expect(try repo.list(contactID: contact.id).first?.text == "Allergic to peanuts")
    }
}
