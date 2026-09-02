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
    notificationID: String? = nil,
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
        notificationID: notificationID,
        deletedAt: deletedAt
    )
}

@Suite("NotificationReconciler")
struct NotificationReconcilerTests {
    private let now = Date()

    private func future(_ seconds: TimeInterval = 3600) -> String {
        ReloraTimestamp.from(now.addingTimeInterval(seconds))
    }

    private func makeReconciler(
        database: AppDatabase,
        center: FakeNotificationCenter
    ) -> NotificationReconciler {
        NotificationReconciler(
            database: database,
            scheduler: NotificationScheduler(center: center, database: database),
            center: center,
            settings: AppSettingsStore(database: database)
        )
    }

    @Test("Does nothing when reminder_notifications_enabled has been turned off")
    func skipsWhenSettingDisabled() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter(status: .authorized)
        try AppSettingsStore(database: database).setBoolean(.reminderNotificationsEnabled, false)

        let target = reminder(contactID: contact.id, remindAt: future())
        try ReminderRepository(database: database).upsert(target)

        await makeReconciler(database: database, center: center).rescheduleAll(userID: contact.userID, trigger: .coldLaunch, now: now)

        #expect(await center.scheduled.isEmpty)
    }

    @Test("reminder_notifications_enabled defaults true when the setting row is absent")
    func defaultsEnabledWhenAbsent() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter(status: .authorized)

        let target = reminder(contactID: contact.id, remindAt: future())
        try ReminderRepository(database: database).upsert(target)

        await makeReconciler(database: database, center: center).rescheduleAll(userID: contact.userID, trigger: .coldLaunch, now: now)

        #expect(await center.scheduled.count == 1)
    }

    @Test("Never requests authorization — only checks, and skips scheduling while not determined")
    func neverRequestsAndSkipsWhenNotDetermined() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter(status: .notDetermined)

        let target = reminder(contactID: contact.id, remindAt: future())
        try ReminderRepository(database: database).upsert(target)

        await makeReconciler(database: database, center: center).rescheduleAll(userID: contact.userID, trigger: .coldLaunch, now: now)

        #expect(await center.requestAuthorizationCallCount == 0)
        #expect(await center.scheduled.isEmpty)
    }

    @Test("Skips scheduling when authorization was denied")
    func skipsWhenDenied() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter(status: .denied)

        let target = reminder(contactID: contact.id, remindAt: future())
        try ReminderRepository(database: database).upsert(target)

        await makeReconciler(database: database, center: center).rescheduleAll(userID: contact.userID, trigger: .coldLaunch, now: now)

        #expect(await center.scheduled.isEmpty)
    }

    @Test("Provisional authorization is treated as sufficient, the same as authorized")
    func provisionalIsSufficient() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter(status: .provisional)

        let target = reminder(contactID: contact.id, remindAt: future())
        try ReminderRepository(database: database).upsert(target)

        await makeReconciler(database: database, center: center).rescheduleAll(userID: contact.userID, trigger: .coldLaunch, now: now)

        #expect(await center.scheduled.count == 1)
    }

    @Test("Schedules a row that needs one, including one landing with notification_id = NULL from a voice save")
    func schedulesRowsNeedingOne() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter(status: .authorized)

        let voiceSaved = reminder(contactID: contact.id, title: "Send the deck", remindAt: future(), notificationID: nil)
        try ReminderRepository(database: database).upsert(voiceSaved)

        await makeReconciler(database: database, center: center).rescheduleAll(userID: contact.userID, trigger: .voiceCaptureSaved, now: now)

        let scheduled = await center.scheduled
        #expect(scheduled.map(\.title) == ["Send the deck"])
        #expect(try ReminderRepository(database: database).get(id: voiceSaved.id)?.notificationID != nil)
    }

    @Test("Never re-schedules a row that already holds a notification id")
    func skipsRowsAlreadyScheduled() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter(status: .authorized, initialPending: ["already-filed"])

        let alreadyScheduled = reminder(contactID: contact.id, remindAt: future(), notificationID: "already-filed")
        try ReminderRepository(database: database).upsert(alreadyScheduled)

        await makeReconciler(database: database, center: center).rescheduleAll(userID: contact.userID, trigger: .coldLaunch, now: now)

        #expect(await center.scheduled.isEmpty)
    }

    @Test("Never schedules a dismissed reminder")
    func neverSchedulesDismissed() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter(status: .authorized)

        let done = reminder(contactID: contact.id, remindAt: future(), status: .dismissed)
        try ReminderRepository(database: database).upsert(done)

        await makeReconciler(database: database, center: center).rescheduleAll(userID: contact.userID, trigger: .coldLaunch, now: now)

        #expect(await center.scheduled.isEmpty)
    }

    @Test("Never schedules a tombstoned reminder")
    func neverSchedulesTombstoned() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter(status: .authorized)
        let repo = ReminderRepository(database: database)

        let target = reminder(contactID: contact.id, remindAt: future())
        try repo.upsert(target)
        _ = try repo.softDelete(itemID: target.id, contactID: contact.id, userID: contact.userID)

        await makeReconciler(database: database, center: center).rescheduleAll(userID: contact.userID, trigger: .coldLaunch, now: now)

        #expect(await center.scheduled.isEmpty)
    }

    @Test("Never schedules the tutorial seed's reminder, identified by its row id in app settings")
    func neverSchedulesTutorialReminder() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter(status: .authorized)

        let tutorial = reminder(contactID: contact.id, title: "Say hi to your example contact", remindAt: future())
        try ReminderRepository(database: database).upsert(tutorial)
        try AppSettingsStore(database: database).setRawValue(.onboardingTutorialReminderID, tutorial.id)

        await makeReconciler(database: database, center: center).rescheduleAll(userID: contact.userID, trigger: .coldLaunch, now: now)

        #expect(await center.scheduled.isEmpty)
    }

    @Test("Cancels an orphaned pending notification with no live scheduled row behind it, but leaves a live one alone")
    func cancelsOrphansOnly() async throws {
        let database = try AppDatabase.inMemory()
        let contact = try makeContact(database)
        let center = FakeNotificationCenter(status: .authorized, initialPending: ["keep-me", "orphan-1"])

        let live = reminder(contactID: contact.id, remindAt: future(), notificationID: "keep-me")
        try ReminderRepository(database: database).upsert(live)

        await makeReconciler(database: database, center: center).rescheduleAll(userID: contact.userID, trigger: .coldLaunch, now: now)

        #expect(await center.removedIDCalls == [["orphan-1"]])
    }

    @Test("A reconciliation pass for one user never touches another user's reminders")
    func scopedToOneUser() async throws {
        let database = try AppDatabase.inMemory()
        let contactA = try makeContact(database, id: "contact-a", userID: "user-a")
        let contactB = try makeContact(database, id: "contact-b", userID: "user-b")
        let center = FakeNotificationCenter(status: .authorized)

        try ReminderRepository(database: database).upsert(reminder(contactID: contactA.id, userID: "user-a", title: "A's reminder", remindAt: future()))
        try ReminderRepository(database: database).upsert(reminder(contactID: contactB.id, userID: "user-b", title: "B's reminder", remindAt: future()))

        await makeReconciler(database: database, center: center).rescheduleAll(userID: "user-a", trigger: .coldLaunch, now: now)

        let scheduled = await center.scheduled
        #expect(scheduled.map(\.title) == ["A's reminder"])
    }
}
