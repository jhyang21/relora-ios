import Testing
@testable import ReloraData
import ReloraCore
import GRDB

@Suite("contacts.last_interaction_at triggers")
struct TriggerTests {
    @Test("inserting a memory sets the parent's last_interaction_at and bumps updated_at")
    func insertMemoryRecomputesInteraction() throws {
        let database = try Fixtures.makeDatabase()
        let contactRepo = ContactRepository(database: database)
        let memoryRepo = MemoryRepository(database: database)

        let contact = Fixtures.makeContact()
        try contactRepo.upsert(id: contact.id, userID: contact.userID, name: contact.name, createdAt: contact.createdAt)

        let before = try contactRepo.getContactsByIDs([contact.id], userID: contact.userID).first
        #expect(before?.lastInteractionAt == nil)
        let originalUpdatedAt = before?.updatedAt

        let memory = Fixtures.makeMemory(contactID: contact.id, text: "First meeting")
        try memoryRepo.upsert(memory)

        let after = try contactRepo.getContactsByIDs([contact.id], userID: contact.userID).first
        #expect(after?.lastInteractionAt == memory.updatedAt)
        #expect(after?.updatedAt != originalUpdatedAt, "trigger must bump contacts.updated_at, not just last_interaction_at")
    }

    @Test("inserting a key thing sets the parent's last_interaction_at")
    func insertKeyThingRecomputesInteraction() throws {
        let database = try Fixtures.makeDatabase()
        let contactRepo = ContactRepository(database: database)
        let keyThingRepo = KeyThingRepository(database: database)

        let contact = Fixtures.makeContact()
        try contactRepo.upsert(id: contact.id, userID: contact.userID, name: contact.name, createdAt: contact.createdAt)

        let keyThing = Fixtures.makeKeyThing(contactID: contact.id)
        try keyThingRepo.upsert(keyThing)

        let after = try contactRepo.getContactsByIDs([contact.id], userID: contact.userID).first
        #expect(after?.lastInteractionAt == keyThing.updatedAt)
    }

    @Test("last_interaction_at recomputes as MAX(updated_at) across both tables")
    func recomputesAsMaxAcrossTables() throws {
        let database = try Fixtures.makeDatabase()
        let contactRepo = ContactRepository(database: database)
        let memoryRepo = MemoryRepository(database: database)
        let keyThingRepo = KeyThingRepository(database: database)

        let contact = Fixtures.makeContact()
        try contactRepo.upsert(id: contact.id, userID: contact.userID, name: contact.name, createdAt: contact.createdAt)

        let memory = Fixtures.makeMemory(contactID: contact.id)
        try memoryRepo.upsert(memory)
        let afterMemory = try contactRepo.getContactsByIDs([contact.id], userID: contact.userID).first
        #expect(afterMemory?.lastInteractionAt == memory.updatedAt)

        // A later key thing should push last_interaction_at forward.
        let keyThing = Fixtures.makeKeyThing(contactID: contact.id)
        try keyThingRepo.upsert(keyThing)
        let afterKeyThing = try contactRepo.getContactsByIDs([contact.id], userID: contact.userID).first
        #expect(afterKeyThing?.lastInteractionAt == keyThing.updatedAt)
    }

    @Test("soft-deleting the only memory clears last_interaction_at back to nil")
    func softDeleteRecomputesToNil() throws {
        let database = try Fixtures.makeDatabase()
        let contactRepo = ContactRepository(database: database)
        let memoryRepo = MemoryRepository(database: database)

        let contact = Fixtures.makeContact()
        try contactRepo.upsert(id: contact.id, userID: contact.userID, name: contact.name, createdAt: contact.createdAt)

        let memory = Fixtures.makeMemory(contactID: contact.id)
        try memoryRepo.upsert(memory)
        let beforeDelete = try contactRepo.getContactsByIDs([contact.id], userID: contact.userID).first
        #expect(beforeDelete?.lastInteractionAt != nil)

        _ = try memoryRepo.softDelete(itemID: memory.id, contactID: contact.id, userID: contact.userID)

        let afterDelete = try contactRepo.getContactsByIDs([contact.id], userID: contact.userID).first
        #expect(afterDelete?.lastInteractionAt == nil)
    }

    @Test("soft-deleting one of two memories falls back to the remaining one's updated_at")
    func softDeleteFallsBackToRemainingRow() throws {
        let database = try Fixtures.makeDatabase()
        let contactRepo = ContactRepository(database: database)
        let memoryRepo = MemoryRepository(database: database)

        let contact = Fixtures.makeContact()
        try contactRepo.upsert(id: contact.id, userID: contact.userID, name: contact.name, createdAt: contact.createdAt)

        let older = Fixtures.makeMemory(contactID: contact.id, text: "Older")
        try memoryRepo.upsert(older)
        // Force a later timestamp so ordering is unambiguous.
        var later = Fixtures.makeMemory(contactID: contact.id, text: "Newer")
        later.updatedAt = ReloraTimestamp.from(Date().addingTimeInterval(1))
        later.createdAt = later.updatedAt
        try memoryRepo.upsert(later)

        _ = try memoryRepo.softDelete(itemID: later.id, contactID: contact.id, userID: contact.userID)

        let after = try contactRepo.getContactsByIDs([contact.id], userID: contact.userID).first
        #expect(after?.lastInteractionAt == older.updatedAt)
    }

    @Test("deleting a memory row nulls out any reminder that pointed to it")
    func beforeDeleteTriggerNullsReminderMemoryID() throws {
        let database = try Fixtures.makeDatabase()
        let contactRepo = ContactRepository(database: database)
        let memoryRepo = MemoryRepository(database: database)
        let reminderRepo = ReminderRepository(database: database)

        let contact = Fixtures.makeContact()
        try contactRepo.upsert(id: contact.id, userID: contact.userID, name: contact.name, createdAt: contact.createdAt)

        let memory = Fixtures.makeMemory(contactID: contact.id)
        try memoryRepo.upsert(memory)

        let reminder = Fixtures.makeReminder(contactID: contact.id, memoryID: memory.id)
        try reminderRepo.upsert(reminder)

        // Hard-delete the memory row directly to exercise the BEFORE DELETE
        // trigger (soft-delete never issues a real DELETE).
        try database.write { db in
            try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [memory.id])
        }

        let reloaded = try reminderRepo.get(id: reminder.id)
        #expect(reloaded?.memoryID == nil)
    }
}
