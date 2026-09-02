import Testing
@testable import ReloraData
import ReloraCore
import GRDB

@Suite("ContactItemStore")
struct ContactItemStoreTests {
    private func makeContact(_ database: AppDatabase) throws -> Contact {
        let contactRepo = ContactRepository(database: database)
        let contact = Fixtures.makeContact()
        try contactRepo.upsert(id: contact.id, userID: contact.userID, name: contact.name, createdAt: contact.createdAt)
        return contact
    }

    @Test("softDelete on a memory tombstones it and reports deleted = true")
    func softDeleteMemoryTombstones() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let memoryRepo = MemoryRepository(database: database)
        let memory = Fixtures.makeMemory(contactID: contact.id)
        try memoryRepo.upsert(memory)

        let result = try database.write { db in
            try ContactItemStore.softDelete(db, kind: .memory, itemID: memory.id, contactID: contact.id, userID: contact.userID)
        }
        #expect(result.deleted)
        #expect(result.canceledNotificationIDs.isEmpty)
    }

    @Test("softDelete is idempotent: a repeat call against an already-deleted row reports deleted = false")
    func softDeleteRepeatedCallReportsFalse() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let memoryRepo = MemoryRepository(database: database)
        let memory = Fixtures.makeMemory(contactID: contact.id)
        try memoryRepo.upsert(memory)

        _ = try database.write { db in
            try ContactItemStore.softDelete(db, kind: .memory, itemID: memory.id, contactID: contact.id, userID: contact.userID)
        }
        let second = try database.write { db in
            try ContactItemStore.softDelete(db, kind: .memory, itemID: memory.id, contactID: contact.id, userID: contact.userID)
        }
        #expect(second.deleted == false)
    }

    @Test("softDelete on a reminder with a notification captures and clears the notification id")
    func softDeleteReminderCapturesNotificationID() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let reminderRepo = ReminderRepository(database: database)
        var reminder = Fixtures.makeReminder(contactID: contact.id)
        reminder.notificationID = "notif-1"
        try reminderRepo.upsert(reminder)

        let result = try database.write { db in
            try ContactItemStore.softDelete(db, kind: .reminder, itemID: reminder.id, contactID: contact.id, userID: contact.userID)
        }
        #expect(result.deleted)
        #expect(result.canceledNotificationIDs == ["notif-1"])

        // The stored row's notification_id is cleared.
        let reloaded = try reminderRepo.get(id: reminder.id)
        #expect(reloaded?.notificationID == nil)
    }

    @Test("softDelete on a reminder with no notification reports an empty cancel list")
    func softDeleteReminderWithoutNotificationReportsEmptyList() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let reminderRepo = ReminderRepository(database: database)
        let reminder = Fixtures.makeReminder(contactID: contact.id)
        try reminderRepo.upsert(reminder)

        let result = try database.write { db in
            try ContactItemStore.softDelete(db, kind: .reminder, itemID: reminder.id, contactID: contact.id, userID: contact.userID)
        }
        #expect(result.deleted)
        #expect(result.canceledNotificationIDs.isEmpty)
    }

    @Test("restore brings back a soft-deleted key thing")
    func restoreKeyThingSucceeds() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let keyThingRepo = KeyThingRepository(database: database)
        let keyThing = Fixtures.makeKeyThing(contactID: contact.id)
        try keyThingRepo.upsert(keyThing)

        let deleteResult = try database.write { db in
            try ContactItemStore.softDelete(db, kind: .keyThing, itemID: keyThing.id, contactID: contact.id, userID: contact.userID)
        }
        let restoreResult = try database.write { db in
            try ContactItemStore.restore(db, kind: .keyThing, itemID: keyThing.id, contactID: contact.id, userID: contact.userID, deletedAt: deleteResult.deletedAt)
        }
        #expect(restoreResult.restored)
        #expect(try keyThingRepo.list(contactID: contact.id).count == 1)
    }

    @Test("restore against a stale/wrong deletedAt matches nothing")
    func restoreWithWrongDeletedAtMatchesNothing() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let keyThingRepo = KeyThingRepository(database: database)
        let keyThing = Fixtures.makeKeyThing(contactID: contact.id)
        try keyThingRepo.upsert(keyThing)

        _ = try database.write { db in
            try ContactItemStore.softDelete(db, kind: .keyThing, itemID: keyThing.id, contactID: contact.id, userID: contact.userID)
        }
        let restoreResult = try database.write { db in
            try ContactItemStore.restore(db, kind: .keyThing, itemID: keyThing.id, contactID: contact.id, userID: contact.userID, deletedAt: "2000-01-01T00:00:00.000Z")
        }
        #expect(restoreResult.restored == false)
    }

    @Test("restore is refused when the parent contact is itself tombstoned")
    func restoreRefusedWhenParentContactTombstoned() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let contactRepo = ContactRepository(database: database)
        let memoryRepo = MemoryRepository(database: database)
        let memory = Fixtures.makeMemory(contactID: contact.id)
        try memoryRepo.upsert(memory)

        let deleteResult = try database.write { db in
            try ContactItemStore.softDelete(db, kind: .memory, itemID: memory.id, contactID: contact.id, userID: contact.userID)
        }
        // Now tombstone the whole contact before the item's undo runs.
        try contactRepo.softDelete(contactID: contact.id, userID: contact.userID)

        let restoreResult = try database.write { db in
            try ContactItemStore.restore(db, kind: .memory, itemID: memory.id, contactID: contact.id, userID: contact.userID, deletedAt: deleteResult.deletedAt)
        }
        #expect(restoreResult.restored == false)
    }

    @Test("restore on a reminder still scheduled returns a RestorableReminder to reschedule")
    func restoreScheduledReminderReturnsRescheduleHandle() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let reminderRepo = ReminderRepository(database: database)
        let reminder = Fixtures.makeReminder(contactID: contact.id, title: "Ping them", status: .scheduled)
        try reminderRepo.upsert(reminder)

        let deleteResult = try database.write { db in
            try ContactItemStore.softDelete(db, kind: .reminder, itemID: reminder.id, contactID: contact.id, userID: contact.userID)
        }
        let restoreResult = try database.write { db in
            try ContactItemStore.restore(db, kind: .reminder, itemID: reminder.id, contactID: contact.id, userID: contact.userID, deletedAt: deleteResult.deletedAt)
        }
        #expect(restoreResult.restored)
        #expect(restoreResult.reminderToReschedule?.id == reminder.id)
        #expect(restoreResult.reminderToReschedule?.title == "Ping them")
        #expect(restoreResult.reminderToReschedule?.status == .scheduled)
    }

    @Test("restore on a dismissed reminder still returns it, unfiltered by status")
    func restoreDismissedReminderStillReturnsHandle() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let reminderRepo = ReminderRepository(database: database)
        let reminder = Fixtures.makeReminder(contactID: contact.id, status: .dismissed)
        try reminderRepo.upsert(reminder)

        let deleteResult = try database.write { db in
            try ContactItemStore.softDelete(db, kind: .reminder, itemID: reminder.id, contactID: contact.id, userID: contact.userID)
        }
        let restoreResult = try database.write { db in
            try ContactItemStore.restore(db, kind: .reminder, itemID: reminder.id, contactID: contact.id, userID: contact.userID, deletedAt: deleteResult.deletedAt)
        }
        #expect(restoreResult.restored)
        #expect(restoreResult.reminderToReschedule?.status == .dismissed)
    }

    @Test("restore on a memory or key thing never sets reminderToReschedule")
    func restoreNonReminderNeverSetsRescheduleHandle() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let memoryRepo = MemoryRepository(database: database)
        let memory = Fixtures.makeMemory(contactID: contact.id)
        try memoryRepo.upsert(memory)

        let deleteResult = try database.write { db in
            try ContactItemStore.softDelete(db, kind: .memory, itemID: memory.id, contactID: contact.id, userID: contact.userID)
        }
        let restoreResult = try database.write { db in
            try ContactItemStore.restore(db, kind: .memory, itemID: memory.id, contactID: contact.id, userID: contact.userID, deletedAt: deleteResult.deletedAt)
        }
        #expect(restoreResult.restored)
        #expect(restoreResult.reminderToReschedule == nil)
    }
}
