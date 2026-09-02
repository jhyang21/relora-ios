import Testing
@testable import ReloraData
import ReloraCore
import GRDB

@Suite("ReminderRepository")
struct ReminderRepositoryTests {
    private func makeContact(_ database: AppDatabase) throws -> Contact {
        let contactRepo = ContactRepository(database: database)
        let contact = Fixtures.makeContact()
        try contactRepo.upsert(id: contact.id, userID: contact.userID, name: contact.name, createdAt: contact.createdAt)
        return contact
    }

    @Test("upsert without a memoryID succeeds and marks the row dirty")
    func upsertWithoutMemoryIDSucceeds() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = ReminderRepository(database: database)

        let reminder = Fixtures.makeReminder(contactID: contact.id, title: "Call back")
        try repo.upsert(reminder)

        let loaded = try repo.get(id: reminder.id)
        #expect(loaded?.title == "Call back")
        #expect(loaded?.isDirty == true)
        #expect(loaded?.dirtyAt != nil)
    }

    @Test("upsert with a memoryID under the same contact and user succeeds")
    func upsertWithValidMemoryLinkSucceeds() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let memoryRepo = MemoryRepository(database: database)
        let reminderRepo = ReminderRepository(database: database)

        let memory = Fixtures.makeMemory(contactID: contact.id)
        try memoryRepo.upsert(memory)

        let reminder = Fixtures.makeReminder(contactID: contact.id, memoryID: memory.id)
        try reminderRepo.upsert(reminder)

        #expect(try reminderRepo.get(id: reminder.id)?.memoryID == memory.id)
    }

    @Test("upsert with a memoryID under a different contact throws reminderMemoryMismatch")
    func upsertWithMismatchedContactThrows() throws {
        let database = try Fixtures.makeDatabase()
        let contactRepo = ContactRepository(database: database)
        let memoryRepo = MemoryRepository(database: database)
        let reminderRepo = ReminderRepository(database: database)

        let contactA = try makeContact(database)
        let contactB = Fixtures.makeContact(name: "Other Contact")
        try contactRepo.upsert(id: contactB.id, userID: contactB.userID, name: contactB.name, createdAt: contactB.createdAt)

        let memoryUnderB = Fixtures.makeMemory(contactID: contactB.id)
        try memoryRepo.upsert(memoryUnderB)

        let reminder = Fixtures.makeReminder(contactID: contactA.id, memoryID: memoryUnderB.id)
        #expect(throws: ReloraDataError.reminderMemoryMismatch) {
            try reminderRepo.upsert(reminder)
        }
    }

    @Test("upsert with a memoryID that does not exist at all throws reminderMemoryMismatch")
    func upsertWithMissingMemoryThrows() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let reminderRepo = ReminderRepository(database: database)

        let reminder = Fixtures.makeReminder(contactID: contact.id, memoryID: "does-not-exist")
        #expect(throws: ReloraDataError.reminderMemoryMismatch) {
            try reminderRepo.upsert(reminder)
        }
    }

    @Test("upsert with a memoryID pointing at a soft-deleted memory still succeeds")
    func upsertWithTombstonedMemoryStillSucceeds() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let memoryRepo = MemoryRepository(database: database)
        let reminderRepo = ReminderRepository(database: database)

        let memory = Fixtures.makeMemory(contactID: contact.id)
        try memoryRepo.upsert(memory)
        _ = try memoryRepo.softDelete(itemID: memory.id, contactID: contact.id, userID: contact.userID)

        let reminder = Fixtures.makeReminder(contactID: contact.id, memoryID: memory.id)
        try reminderRepo.upsert(reminder)

        #expect(try reminderRepo.get(id: reminder.id)?.memoryID == memory.id)
    }

    @Test("get(id:) hydrates the full row including notification_id")
    func getHydratesFullRow() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = ReminderRepository(database: database)

        var reminder = Fixtures.makeReminder(contactID: contact.id)
        reminder.notificationID = "os-notification-42"
        try repo.upsert(reminder)

        let loaded = try repo.get(id: reminder.id)
        #expect(loaded?.notificationID == "os-notification-42")
    }

    @Test("get(id:) returns nil for a missing id")
    func getReturnsNilForMissingID() throws {
        let database = try Fixtures.makeDatabase()
        let repo = ReminderRepository(database: database)
        #expect(try repo.get(id: "missing") == nil)
    }

    @Test("list projects a narrow column set, leaving isDirty/dirtyAt/notificationID at defaults")
    func listProjectsNarrowColumnSet() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = ReminderRepository(database: database)

        var reminder = Fixtures.makeReminder(contactID: contact.id)
        reminder.notificationID = "should-not-appear-in-list"
        try repo.upsert(reminder)

        let listed = try repo.list(contactID: contact.id).first
        #expect(listed?.isDirty == false)
        #expect(listed?.dirtyAt == nil)
        #expect(listed?.notificationID == nil)

        // The full row still carries the real values.
        #expect(try repo.get(id: reminder.id)?.notificationID == "should-not-appear-in-list")
    }

    @Test("list orders active reminders by remind_at ascending and excludes soft-deleted rows")
    func listOrdersByRemindAtAscending() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = ReminderRepository(database: database)

        let later = Fixtures.makeReminder(contactID: contact.id, title: "Later", remindAt: "2026-09-10T00:00:00.000Z")
        try repo.upsert(later)
        let sooner = Fixtures.makeReminder(contactID: contact.id, title: "Sooner", remindAt: "2026-09-01T00:00:00.000Z")
        try repo.upsert(sooner)
        let deleted = Fixtures.makeReminder(contactID: contact.id, title: "Deleted", remindAt: "2026-09-05T00:00:00.000Z")
        try repo.upsert(deleted)
        _ = try repo.softDelete(itemID: deleted.id, contactID: contact.id, userID: contact.userID)

        let listed = try repo.list(contactID: contact.id)
        #expect(listed.map(\.title) == ["Sooner", "Later"])
    }

    @Test("list caps at 1000 rows per contact")
    func listCapsAtOneThousandPerContact() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        try database.write { db in
            for index in 0..<1001 {
                let padded = String(format: "%05d", index)
                try db.execute(
                    sql: """
                        INSERT INTO reminders (id, contact_id, user_id, title, remind_at, status, created_at, updated_at, is_dirty)
                        VALUES (?, ?, ?, ?, ?, 'scheduled', ?, ?, 0)
                        """,
                    arguments: [
                        "reminder-\(padded)", contact.id, contact.userID, "Reminder \(padded)",
                        "2026-01-01T00:00:00.\(padded)Z", "2026-01-01T00:00:00.\(padded)Z", "2026-01-01T00:00:00.\(padded)Z"
                    ]
                )
            }
        }

        let repo = ReminderRepository(database: database)
        #expect(try repo.list(contactID: contact.id).count == 1000)
    }

    @Test("listByUser caps at 10000 rows across all of a user's contacts")
    func listByUserCapsAtTenThousand() throws {
        let database = try Fixtures.makeDatabase()
        let contactRepo = ContactRepository(database: database)
        let userID = "cap-test-user"
        try contactRepo.upsert(id: "contact-cap", userID: userID, name: "Cap Contact", createdAt: ReloraTimestamp.now())

        try database.write { db in
            for index in 0..<10001 {
                let padded = String(format: "%06d", index)
                try db.execute(
                    sql: """
                        INSERT INTO reminders (id, contact_id, user_id, title, remind_at, status, created_at, updated_at, is_dirty)
                        VALUES (?, 'contact-cap', ?, ?, ?, 'scheduled', ?, ?, 0)
                        """,
                    arguments: [
                        "reminder-\(padded)", userID, "Reminder \(padded)",
                        "2026-01-01T00:00:00.\(padded)Z", "2026-01-01T00:00:00.\(padded)Z", "2026-01-01T00:00:00.\(padded)Z"
                    ]
                )
            }
        }

        let repo = ReminderRepository(database: database)
        #expect(try repo.listByUser(userID: userID).count == 10000)
    }

    // MARK: - listFullByUser (M8)

    @Test("listFullByUser hydrates the full row, notification_id included, unlike listByUser")
    func listFullByUserHydratesFullRow() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = ReminderRepository(database: database)

        let reminder = Fixtures.makeReminder(contactID: contact.id)
        try repo.upsert(reminder)
        try repo.setNotificationID(reminder.id, notificationID: "os-notification-full")

        let loaded = try repo.listFullByUser(userID: contact.userID).first
        #expect(loaded?.notificationID == "os-notification-full")
        #expect(loaded?.isDirty == true)
    }

    @Test("listFullByUser orders by remind_at ascending and excludes soft-deleted rows")
    func listFullByUserOrdersAndExcludesDeleted() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = ReminderRepository(database: database)

        let later = Fixtures.makeReminder(contactID: contact.id, title: "Later", remindAt: "2026-09-10T00:00:00.000Z")
        try repo.upsert(later)
        let sooner = Fixtures.makeReminder(contactID: contact.id, title: "Sooner", remindAt: "2026-09-01T00:00:00.000Z")
        try repo.upsert(sooner)
        let deleted = Fixtures.makeReminder(contactID: contact.id, title: "Deleted", remindAt: "2026-09-05T00:00:00.000Z")
        try repo.upsert(deleted)
        _ = try repo.softDelete(itemID: deleted.id, contactID: contact.id, userID: contact.userID)

        let listed = try repo.listFullByUser(userID: contact.userID)
        #expect(listed.map(\.title) == ["Sooner", "Later"])
    }

    @Test("listFullByUser spans every contact belonging to the user")
    func listFullByUserSpansContacts() throws {
        let database = try Fixtures.makeDatabase()
        let contactRepo = ContactRepository(database: database)
        let repo = ReminderRepository(database: database)
        let userID = "full-user"

        try contactRepo.upsert(id: "contact-a", userID: userID, name: "A", createdAt: ReloraTimestamp.now())
        try contactRepo.upsert(id: "contact-b", userID: userID, name: "B", createdAt: ReloraTimestamp.now())

        try repo.upsert(Fixtures.makeReminder(contactID: "contact-a", userID: userID, title: "From A"))
        try repo.upsert(Fixtures.makeReminder(contactID: "contact-b", userID: userID, title: "From B"))

        #expect(try repo.listFullByUser(userID: userID).map(\.title).sorted() == ["From A", "From B"])
    }

    // MARK: - setNotificationID (M8)

    @Test("setNotificationID writes the id without marking the row dirty")
    func setNotificationIDWritesWithoutDirtying() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = ReminderRepository(database: database)

        let reminder = Fixtures.makeReminder(contactID: contact.id)
        try repo.upsert(reminder)

        // `upsert` always dirties; write again through a path that must not,
        // then read the flag back through a full row.
        try database.write { db in
            try db.execute(sql: "UPDATE reminders SET is_dirty = 0 WHERE id = ?", arguments: [reminder.id])
        }

        try repo.setNotificationID(reminder.id, notificationID: "os-notification-set")

        let loaded = try repo.get(id: reminder.id)
        #expect(loaded?.notificationID == "os-notification-set")
        #expect(loaded?.isDirty == false)
    }

    @Test("setNotificationID with nil clears an existing id")
    func setNotificationIDClearsWithNil() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let repo = ReminderRepository(database: database)

        var reminder = Fixtures.makeReminder(contactID: contact.id)
        reminder.notificationID = "will-be-cleared"
        try repo.upsert(reminder)

        try repo.setNotificationID(reminder.id, notificationID: nil)
        #expect(try repo.get(id: reminder.id)?.notificationID == nil)
    }
}
