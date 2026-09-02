import Foundation
import Testing
import ReloraCore
import ReloraData
import ReloraServices

// MARK: - Fixtures

private func makeContact(_ database: AppDatabase, id: String = ReloraID.new(), userID: String = "user-1") throws -> Contact {
    let contactRepo = ContactRepository(database: database)
    let now = ReloraTimestamp.now()
    try contactRepo.upsert(id: id, userID: userID, name: "Ada Lovelace", createdAt: now)
    return Contact(id: id, userID: userID, name: "Ada Lovelace", descriptors: [], createdAt: now, updatedAt: now)
}

private func reminder(
    id: String = ReloraID.new(),
    contactID: String,
    userID: String = "user-1",
    title: String = "Follow up",
    remindAt: String,
    status: ReminderStatus = .scheduled,
    deletedAt: String? = nil
) -> Reminder {
    let now = ReloraTimestamp.now()
    return Reminder(
        id: id,
        contactID: contactID,
        userID: userID,
        title: title,
        remindAt: remindAt,
        status: status,
        createdAt: now,
        updatedAt: now,
        deletedAt: deletedAt
    )
}

@Suite("NotificationScheduler")
struct NotificationSchedulerTests {
    private let now = Date()

    private func future(_ seconds: TimeInterval = 3600) -> String {
        ReloraTimestamp.from(now.addingTimeInterval(seconds))
    }

    private func past(_ seconds: TimeInterval = 3600) -> String {
        ReloraTimestamp.from(now.addingTimeInterval(-seconds))
    }

    @Test("Schedules a live, future reminder and writes the notification id back onto the row")
    func schedulesAndWritesBackID() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center, database: database)

        let target = reminder(contactID: contact.id, remindAt: future())
        try ReminderRepository(database: database).upsert(target)

        let succeeded = await scheduler.schedule(target, now: now)
        #expect(succeeded)

        let scheduled = await center.scheduled
        #expect(scheduled.count == 1)
        #expect(scheduled.first?.title == "Follow up")
        #expect(scheduled.first?.userInfo["url"] == "relora://contact/\(contact.id)")

        let mintedID = scheduled.first?.id
        #expect(mintedID != nil)
        let loaded = try ReminderRepository(database: database).get(id: target.id)
        #expect(loaded?.notificationID == mintedID)
    }

    @Test("Skips a reminder that is not .scheduled")
    func skipsNonScheduledStatus() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center, database: database)

        let dismissed = reminder(contactID: contact.id, remindAt: future(), status: .dismissed)
        let succeeded = await scheduler.schedule(dismissed, now: now)

        #expect(!succeeded)
        #expect(await center.scheduled.isEmpty)
    }

    @Test("Skips a tombstoned reminder")
    func skipsTombstoned() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center, database: database)

        let deleted = reminder(contactID: contact.id, remindAt: future(), deletedAt: ReloraTimestamp.now())
        let succeeded = await scheduler.schedule(deleted, now: now)

        #expect(!succeeded)
        #expect(await center.scheduled.isEmpty)
    }

    @Test("Skips a past-due reminder rather than filing a request that can never fire")
    func skipsPastDue() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center, database: database)

        let overdue = reminder(contactID: contact.id, remindAt: past())
        let succeeded = await scheduler.schedule(overdue, now: now)

        #expect(!succeeded)
        #expect(await center.scheduled.isEmpty)
    }

    @Test("A center failure to schedule leaves no notification id written")
    func centerFailureWritesNothing() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter()
        await center.setScheduleShouldThrow(true)
        let scheduler = NotificationScheduler(center: center, database: database)

        let target = reminder(contactID: contact.id, remindAt: future())
        try ReminderRepository(database: database).upsert(target)

        let succeeded = await scheduler.schedule(target, now: now)
        #expect(!succeeded)
        #expect(try ReminderRepository(database: database).get(id: target.id)?.notificationID == nil)
    }

    @Test("cancel removes exactly the given ids from the center, the first step of the two-step ordering")
    func cancelRemovesGivenIDs() async throws {
        let database = try AppDatabase.inMemory()
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center, database: database)

        await scheduler.cancel(["a", "b"])
        #expect(await center.removedIDCalls == [["a", "b"]])
    }

    @Test("reschedule re-fetches each row fresh rather than trusting the restorable's own snapshot")
    func rescheduleUsesFreshRow() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center, database: database)

        let current = reminder(contactID: contact.id, title: "Current title", remindAt: future())
        try ReminderRepository(database: database).upsert(current)

        let stale = RestorableReminder(
            id: current.id,
            contactID: contact.id,
            title: "Stale title",
            remindAt: past(),
            status: .scheduled
        )
        await scheduler.reschedule([stale])

        let scheduled = await center.scheduled
        #expect(scheduled.count == 1)
        #expect(scheduled.first?.title == "Current title")
    }

    @Test("reschedule skips restorables that are not .scheduled")
    func rescheduleSkipsNonScheduled() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center, database: database)

        let dismissed = reminder(contactID: contact.id, remindAt: future(), status: .dismissed)
        try ReminderRepository(database: database).upsert(dismissed)

        let stale = RestorableReminder(id: dismissed.id, contactID: contact.id, title: "x", remindAt: future(), status: .dismissed)
        await scheduler.reschedule([stale])

        #expect(await center.scheduled.isEmpty)
    }

    @Test("reschedule silently skips a restorable whose row no longer exists")
    func rescheduleSkipsMissingRow() async throws {
        let database = try AppDatabase.inMemory()
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center, database: database)

        let ghost = RestorableReminder(id: "missing", contactID: "contact-x", title: "x", remindAt: future(), status: .scheduled)
        await scheduler.reschedule([ghost])

        #expect(await center.scheduled.isEmpty)
    }
}
