import Testing
@testable import ReloraData
import ReloraCore
import GRDB

@Suite("ContactRepository")
struct ContactRepositoryTests {
    @Test("upsert inserts a new contact and marks it dirty")
    func upsertInsertsDirtyRow() throws {
        let database = try Fixtures.makeDatabase()
        let repo = ContactRepository(database: database)
        let contact = Fixtures.makeContact(descriptors: ["engineer", "hiking"], phoneNumber: "555-0100", email: "ada@example.com")

        try repo.upsert(
            id: contact.id,
            userID: contact.userID,
            name: contact.name,
            descriptors: contact.descriptors,
            phoneNumber: contact.phoneNumber,
            email: contact.email,
            createdAt: contact.createdAt
        )

        let loaded = try repo.getContactsByIDs([contact.id], userID: contact.userID).first
        #expect(loaded?.name == contact.name)
        #expect(loaded?.descriptors == ["engineer", "hiking"])
        #expect(loaded?.phoneNumber == "555-0100")
        #expect(loaded?.isDirty == true)
        #expect(loaded?.dirtyAt != nil)
    }

    @Test("upsert without descriptors defaults to an empty array, matching TextJSONArray round trip")
    func upsertDefaultsDescriptorsToEmptyArray() throws {
        let database = try Fixtures.makeDatabase()
        let repo = ContactRepository(database: database)
        let id = ReloraID.new()

        try repo.upsert(id: id, userID: Fixtures.defaultUserID, name: "No Descriptors")

        let loaded = try repo.getContactsByIDs([id], userID: Fixtures.defaultUserID).first
        #expect(loaded?.descriptors == [])
    }

    @Test("omitting lastInteractionAt on a later upsert preserves the existing value")
    func omittedLastInteractionAtIsPreserved() throws {
        let database = try Fixtures.makeDatabase()
        let repo = ContactRepository(database: database)
        let id = ReloraID.new()
        let interactionTimestamp = ReloraTimestamp.now()

        try repo.upsert(id: id, userID: Fixtures.defaultUserID, name: "First", lastInteractionAt: .some(interactionTimestamp))
        let afterFirst = try repo.getContactsByIDs([id], userID: Fixtures.defaultUserID).first
        #expect(afterFirst?.lastInteractionAt == interactionTimestamp)

        // Second upsert omits lastInteractionAt entirely (the default `.none`)
        // — must NOT clear the value the trigger/first write set.
        try repo.upsert(id: id, userID: Fixtures.defaultUserID, name: "Renamed")
        let afterSecond = try repo.getContactsByIDs([id], userID: Fixtures.defaultUserID).first
        #expect(afterSecond?.name == "Renamed")
        #expect(afterSecond?.lastInteractionAt == interactionTimestamp)
    }

    @Test("explicitly passing .some(nil) for lastInteractionAt clears it")
    func explicitNilClearsLastInteractionAt() throws {
        let database = try Fixtures.makeDatabase()
        let repo = ContactRepository(database: database)
        let id = ReloraID.new()

        try repo.upsert(id: id, userID: Fixtures.defaultUserID, name: "First", lastInteractionAt: .some(ReloraTimestamp.now()))
        try repo.upsert(id: id, userID: Fixtures.defaultUserID, name: "First", lastInteractionAt: .some(nil))

        let loaded = try repo.getContactsByIDs([id], userID: Fixtures.defaultUserID).first
        #expect(loaded?.lastInteractionAt == nil)
    }

    @Test("getContactsByIDs preserves the requested id order and omits soft-deleted or missing ids")
    func getContactsByIDsPreservesOrder() throws {
        let database = try Fixtures.makeDatabase()
        let repo = ContactRepository(database: database)
        let first = Fixtures.makeContact(name: "First")
        let second = Fixtures.makeContact(name: "Second")
        let third = Fixtures.makeContact(name: "Third")

        for contact in [first, second, third] {
            try repo.upsert(id: contact.id, userID: contact.userID, name: contact.name, createdAt: contact.createdAt)
        }
        try repo.softDelete(contactID: second.id, userID: Fixtures.defaultUserID)

        let results = try repo.getContactsByIDs([third.id, "missing-id", first.id, second.id], userID: Fixtures.defaultUserID)
        #expect(results.map(\.id) == [third.id, first.id])
    }

    @Test("list orders active contacts by updated_at descending and excludes soft-deleted rows")
    func listOrdersByUpdatedAtDescending() throws {
        let database = try Fixtures.makeDatabase()
        let repo = ContactRepository(database: database)
        let older = Fixtures.makeContact(name: "Older")
        try repo.upsert(id: older.id, userID: older.userID, name: older.name, createdAt: older.createdAt)

        let newer = Fixtures.makeContact(name: "Newer")
        try repo.upsert(id: newer.id, userID: newer.userID, name: newer.name, createdAt: newer.createdAt)

        let deleted = Fixtures.makeContact(name: "Deleted")
        try repo.upsert(id: deleted.id, userID: deleted.userID, name: deleted.name, createdAt: deleted.createdAt)
        try repo.softDelete(contactID: deleted.id, userID: Fixtures.defaultUserID)

        // `upsert` always stamps `updated_at` with the current instant, so
        // back-to-back calls in the same test can land in the same
        // millisecond. Force a strict, deterministic ordering directly so
        // this test does not depend on wall-clock spacing between calls.
        try database.write { db in
            try db.execute(sql: "UPDATE contacts SET updated_at = ? WHERE id = ?", arguments: ["2026-01-01T00:00:00.000Z", older.id])
            try db.execute(sql: "UPDATE contacts SET updated_at = ? WHERE id = ?", arguments: ["2026-01-02T00:00:00.000Z", newer.id])
        }

        let listed = try repo.list(userID: Fixtures.defaultUserID)
        #expect(listed.map(\.name) == ["Newer", "Older"])
    }

    @Test("countContent counts only live children")
    func countContentCountsOnlyLiveChildren() throws {
        let database = try Fixtures.makeDatabase()
        let contactRepo = ContactRepository(database: database)
        let memoryRepo = MemoryRepository(database: database)
        let keyThingRepo = KeyThingRepository(database: database)
        let reminderRepo = ReminderRepository(database: database)

        let contact = Fixtures.makeContact()
        try contactRepo.upsert(id: contact.id, userID: contact.userID, name: contact.name, createdAt: contact.createdAt)

        let keptMemory = Fixtures.makeMemory(contactID: contact.id)
        try memoryRepo.upsert(keptMemory)
        let removedMemory = Fixtures.makeMemory(contactID: contact.id)
        try memoryRepo.upsert(removedMemory)
        _ = try memoryRepo.softDelete(itemID: removedMemory.id, contactID: contact.id, userID: contact.userID)

        try keyThingRepo.upsert(Fixtures.makeKeyThing(contactID: contact.id))
        try reminderRepo.upsert(Fixtures.makeReminder(contactID: contact.id))

        let counts = try contactRepo.countContent(contactID: contact.id, userID: contact.userID)
        #expect(counts.memories == 1)
        #expect(counts.keyThings == 1)
        #expect(counts.reminders == 1)
    }

    @Test("list caps at 2000 rows, matching listContacts' LIMIT")
    func listCapsAtTwoThousand() throws {
        let database = try Fixtures.makeDatabase()
        let userID = "cap-test-user"
        try database.write { db in
            for index in 0..<2001 {
                let padded = String(format: "%05d", index)
                try db.execute(
                    sql: """
                        INSERT INTO contacts (id, user_id, name, descriptors, created_at, updated_at, is_dirty)
                        VALUES (?, ?, ?, '[]', ?, ?, 0)
                        """,
                    arguments: ["contact-\(padded)", userID, "Contact \(padded)", "2026-01-01T00:00:00.\(padded)Z", "2026-01-01T00:00:00.\(padded)Z"]
                )
            }
        }

        let repo = ContactRepository(database: database)
        let listed = try repo.list(userID: userID)
        #expect(listed.count == 2000)
    }
}
