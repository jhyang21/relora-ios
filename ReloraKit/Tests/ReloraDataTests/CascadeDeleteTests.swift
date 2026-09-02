import Testing
@testable import ReloraData
import ReloraCore
import GRDB

@Suite("ContactCascadeDelete")
struct CascadeDeleteTests {
    private func makeContact(_ database: AppDatabase) throws -> Contact {
        let contactRepo = ContactRepository(database: database)
        let contact = Fixtures.makeContact()
        try contactRepo.upsert(id: contact.id, userID: contact.userID, name: contact.name, createdAt: contact.createdAt)
        return contact
    }

    @Test("deleteContactCascade tombstones the contact and every live child row")
    func deleteCascadesToEveryChild() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let memoryRepo = MemoryRepository(database: database)
        let keyThingRepo = KeyThingRepository(database: database)
        let reminderRepo = ReminderRepository(database: database)
        let contactRepo = ContactRepository(database: database)

        let memory = Fixtures.makeMemory(contactID: contact.id)
        try memoryRepo.upsert(memory)
        let keyThing = Fixtures.makeKeyThing(contactID: contact.id)
        try keyThingRepo.upsert(keyThing)
        var reminder = Fixtures.makeReminder(contactID: contact.id)
        reminder.notificationID = "notif-cascade"
        try reminderRepo.upsert(reminder)

        let result = try ContactCascadeDelete.deleteContactCascade(database: database, contactID: contact.id, userID: contact.userID)
        #expect(result.canceledNotificationIDs == ["notif-cascade"])

        #expect(try contactRepo.getContactsByIDs([contact.id], userID: contact.userID).isEmpty)
        #expect(try memoryRepo.list(contactID: contact.id).isEmpty)
        #expect(try keyThingRepo.list(contactID: contact.id).isEmpty)
        #expect(try reminderRepo.list(contactID: contact.id).isEmpty)
    }

    @Test("restoreContactCascade undoes exactly the rows tombstoned by its matching delete")
    func restoreUndoesMatchingDelete() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let memoryRepo = MemoryRepository(database: database)
        let contactRepo = ContactRepository(database: database)
        let memory = Fixtures.makeMemory(contactID: contact.id)
        try memoryRepo.upsert(memory)

        let deleteResult = try ContactCascadeDelete.deleteContactCascade(database: database, contactID: contact.id, userID: contact.userID)
        let restoreResult = try ContactCascadeDelete.restoreContactCascade(database: database, contactID: contact.id, userID: contact.userID, deletedAt: deleteResult.deletedAt)

        #expect(restoreResult.restoredContact)
        #expect(try contactRepo.getContactsByIDs([contact.id], userID: contact.userID).count == 1)
        #expect(try memoryRepo.list(contactID: contact.id).count == 1)
    }

    @Test("a row tombstoned by an earlier, separate delete is not resurrected by a later unrelated restore")
    func earlierTombstoneSurvivesLaterUnrelatedRestore() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let memoryRepo = MemoryRepository(database: database)

        // Delete one memory on its own, well before the cascade delete. Force
        // its tombstone to a fixed, clearly-earlier timestamp so this test
        // does not depend on wall-clock spacing between the two deletes to
        // guarantee distinct `deletedAt` handles.
        let standaloneMemory = Fixtures.makeMemory(contactID: contact.id, text: "Deleted separately")
        try memoryRepo.upsert(standaloneMemory)
        _ = try memoryRepo.softDelete(itemID: standaloneMemory.id, contactID: contact.id, userID: contact.userID)
        let standaloneDeletedAt = "2000-01-01T00:00:00.000Z"
        try database.write { db in
            try db.execute(sql: "UPDATE memories SET deleted_at = ? WHERE id = ?", arguments: [standaloneDeletedAt, standaloneMemory.id])
        }

        // A second, still-live memory that the cascade delete will tombstone.
        let cascadedMemory = Fixtures.makeMemory(contactID: contact.id, text: "Deleted by cascade")
        try memoryRepo.upsert(cascadedMemory)

        let cascadeDeleteResult = try ContactCascadeDelete.deleteContactCascade(database: database, contactID: contact.id, userID: contact.userID)
        #expect(cascadeDeleteResult.deletedAt != standaloneDeletedAt)

        let restoreResult = try ContactCascadeDelete.restoreContactCascade(database: database, contactID: contact.id, userID: contact.userID, deletedAt: cascadeDeleteResult.deletedAt)
        #expect(restoreResult.restoredContact)

        let restored = try memoryRepo.list(contactID: contact.id)
        // Only the cascade-deleted memory comes back; the standalone one keeps
        // its own, earlier tombstone.
        #expect(restored.map(\.text) == ["Deleted by cascade"])
    }

    @Test("restoreContactCascade is idempotent: a repeated call against the same handle matches nothing")
    func restoreIsIdempotent() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let memoryRepo = MemoryRepository(database: database)
        let memory = Fixtures.makeMemory(contactID: contact.id)
        try memoryRepo.upsert(memory)

        let deleteResult = try ContactCascadeDelete.deleteContactCascade(database: database, contactID: contact.id, userID: contact.userID)
        let first = try ContactCascadeDelete.restoreContactCascade(database: database, contactID: contact.id, userID: contact.userID, deletedAt: deleteResult.deletedAt)
        #expect(first.restoredContact)

        let second = try ContactCascadeDelete.restoreContactCascade(database: database, contactID: contact.id, userID: contact.userID, deletedAt: deleteResult.deletedAt)
        #expect(second.restoredContact == false)
        #expect(second.remindersToReschedule.isEmpty)
    }

    @Test("restoreContactCascade returns every restored reminder unfiltered by status")
    func restoreReturnsAllRemindersRegardlessOfStatus() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let reminderRepo = ReminderRepository(database: database)
        let scheduled = Fixtures.makeReminder(contactID: contact.id, title: "Scheduled", status: .scheduled)
        try reminderRepo.upsert(scheduled)
        let dismissed = Fixtures.makeReminder(contactID: contact.id, title: "Dismissed", status: .dismissed)
        try reminderRepo.upsert(dismissed)

        let deleteResult = try ContactCascadeDelete.deleteContactCascade(database: database, contactID: contact.id, userID: contact.userID)
        let restoreResult = try ContactCascadeDelete.restoreContactCascade(database: database, contactID: contact.id, userID: contact.userID, deletedAt: deleteResult.deletedAt)

        let titles = Set(restoreResult.remindersToReschedule.map(\.title))
        #expect(titles == ["Scheduled", "Dismissed"])
    }

    @Test("deleteContactCascade refreshes the search index so a deleted contact drops out of search")
    func deleteRefreshesSearchIndex() throws {
        SearchIndexState.shared.resetForTesting()
        let database = try Fixtures.makeDatabase()
        let contactRepo = ContactRepository(database: database)
        let contact = Fixtures.makeContact(name: "Findable Person")
        try contactRepo.upsert(id: contact.id, userID: contact.userID, name: contact.name, createdAt: contact.createdAt)

        #expect(try ContactSearchIndex.searchContactIDs(database, query: "Findable").contains(contact.id))

        _ = try ContactCascadeDelete.deleteContactCascade(database: database, contactID: contact.id, userID: contact.userID)

        #expect(try ContactSearchIndex.searchContactIDs(database, query: "Findable").contains(contact.id) == false)
    }
}
