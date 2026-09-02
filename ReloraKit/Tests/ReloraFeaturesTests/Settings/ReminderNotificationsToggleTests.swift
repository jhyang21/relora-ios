import Foundation
import Testing
import ReloraCore
import ReloraData
import ReloraServices
@testable import ReloraFeatures

// MARK: - Fixtures

// Defaults to "c1" because the reminder fixtures below reference it and the
// schema enforces FOREIGN KEY(contact_id, user_id) → contacts.
private func makeContact(_ database: AppDatabase, id: String = "c1", userID: String = "user-1") throws {
    let now = ReloraTimestamp.now()
    try ContactRepository(database: database).upsert(id: id, userID: userID, name: "Ada Lovelace", createdAt: now)
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

private func makeEnvironment(_ database: AppDatabase, center: FakeNotificationCenter) -> NotificationEnvironment {
    let scheduler = NotificationScheduler(center: center, database: database)
    let settings = AppSettingsStore(database: database)
    let reconciler = NotificationReconciler(database: database, scheduler: scheduler, center: center, settings: settings)
    return NotificationEnvironment(
        scheduler: scheduler,
        reconciler: reconciler,
        center: center,
        primingStore: ReminderNotificationPrimingStore(database: database)
    )
}

@Suite("ReminderNotificationsToggle.candidates — the pure filter")
struct ReminderNotificationsToggleCandidatesTests {
    private let now = Date()

    private func future(_ seconds: TimeInterval = 3600) -> String {
        ReloraTimestamp.from(now.addingTimeInterval(seconds))
    }

    @Test("Keeps only .scheduled, non-deleted rows")
    func filtersStatusAndTombstone() {
        let live = reminder(contactID: "c1", remindAt: future())
        let dismissed = reminder(contactID: "c1", remindAt: future(), status: .dismissed)
        let deleted = reminder(contactID: "c1", remindAt: future(), deletedAt: ReloraTimestamp.now())

        let result = ReminderNotificationsToggle.candidates(from: [live, dismissed, deleted], excludingTutorialReminderID: nil)
        #expect(result.map(\.id) == [live.id])
    }

    @Test("Excludes the tutorial reminder by id even though it is .scheduled")
    func excludesTutorialReminder() {
        let tutorial = reminder(id: "tutorial-1", contactID: "c1", remindAt: future())
        let ordinary = reminder(contactID: "c1", remindAt: future())

        let result = ReminderNotificationsToggle.candidates(from: [tutorial, ordinary], excludingTutorialReminderID: "tutorial-1")
        #expect(result.map(\.id) == [ordinary.id])
    }

    @Test("A nil tutorial id excludes nothing")
    func nilTutorialIDExcludesNothing() {
        let a = reminder(contactID: "c1", remindAt: future())
        let b = reminder(contactID: "c1", remindAt: future())

        let result = ReminderNotificationsToggle.candidates(from: [a, b], excludingTutorialReminderID: nil)
        #expect(Set(result.map(\.id)) == Set([a.id, b.id]))
    }
}

@Suite("ReminderNotificationsToggle.disable")
struct ReminderNotificationsToggleDisableTests {
    private let now = Date()

    private func future(_ seconds: TimeInterval = 3600) -> String {
        ReloraTimestamp.from(now.addingTimeInterval(seconds))
    }

    @Test("Cancels and clears every one of this user's reminders that carries a notification id, and persists the flag")
    func cancelsAndClearsOwnReminders() async throws {
        let database = try AppDatabase.inMemory()
        try makeContact(database, userID: "user-1")
        let center = FakeNotificationCenter()
        let environment = makeEnvironment(database, center: center)
        let settings = AppSettingsStore(database: database)

        let scheduledOne = reminder(contactID: "c1", remindAt: future(), notificationID: "os-1")
        let scheduledTwo = reminder(contactID: "c1", remindAt: future(), notificationID: "os-2")
        let neverScheduled = reminder(contactID: "c1", remindAt: future(), notificationID: nil)
        for row in [scheduledOne, scheduledTwo, neverScheduled] {
            try ReminderRepository(database: database).upsert(row)
        }

        try await ReminderNotificationsToggle.disable(userID: "user-1", database: database, settings: settings, notifications: environment)

        let removedCalls = await center.removedIDCalls
        #expect(Set(removedCalls.flatMap { $0 }) == Set(["os-1", "os-2"]))

        let repository = ReminderRepository(database: database)
        #expect(try repository.get(id: scheduledOne.id)?.notificationID == nil)
        #expect(try repository.get(id: scheduledTwo.id)?.notificationID == nil)
        #expect(try settings.reminderNotificationsEnabled() == false)
    }

    @Test("Never touches another user's reminders — RN's own cancel step is unscoped, this one is deliberately narrower")
    func neverTouchesAnotherUsersReminders() async throws {
        let database = try AppDatabase.inMemory()
        try makeContact(database, id: "c1", userID: "user-1")
        try makeContact(database, id: "c2", userID: "user-2")
        let center = FakeNotificationCenter()
        let environment = makeEnvironment(database, center: center)
        let settings = AppSettingsStore(database: database)

        let mine = reminder(contactID: "c1", userID: "user-1", remindAt: future(), notificationID: "mine")
        let someoneElses = reminder(contactID: "c2", userID: "user-2", remindAt: future(), notificationID: "not-mine")
        try ReminderRepository(database: database).upsert(mine)
        try ReminderRepository(database: database).upsert(someoneElses)

        try await ReminderNotificationsToggle.disable(userID: "user-1", database: database, settings: settings, notifications: environment)

        let repository = ReminderRepository(database: database)
        #expect(try repository.get(id: mine.id)?.notificationID == nil)
        #expect(try repository.get(id: someoneElses.id)?.notificationID == "not-mine")
    }
}

@Suite("ReminderNotificationsToggle.enable")
struct ReminderNotificationsToggleEnableTests {
    private let now = Date()

    private func future(_ seconds: TimeInterval = 3600) -> String {
        ReloraTimestamp.from(now.addingTimeInterval(seconds))
    }

    @Test("Throws .permissionDenied and mutates nothing when the OS refuses")
    func permissionDeniedMutatesNothing() async throws {
        let database = try AppDatabase.inMemory()
        try makeContact(database, userID: "user-1")
        let center = FakeNotificationCenter(status: .denied)
        let environment = makeEnvironment(database, center: center)
        let settings = AppSettingsStore(database: database)

        let target = reminder(contactID: "c1", remindAt: future())
        try ReminderRepository(database: database).upsert(target)

        await #expect(throws: ReminderNotificationsToggle.ToggleError.permissionDenied) {
            try await ReminderNotificationsToggle.enable(userID: "user-1", database: database, settings: settings, notifications: environment, now: now)
        }

        #expect(try ReminderRepository(database: database).get(id: target.id)?.notificationID == nil)
        #expect(await center.scheduled.isEmpty)
    }

    @Test("Reschedules every scheduled, non-deleted reminder and writes back a fresh id")
    func reschedulesEveryLiveReminder() async throws {
        let database = try AppDatabase.inMemory()
        try makeContact(database, userID: "user-1")
        let center = FakeNotificationCenter(status: .authorized)
        let environment = makeEnvironment(database, center: center)
        let settings = AppSettingsStore(database: database)

        let target = reminder(contactID: "c1", remindAt: future())
        try ReminderRepository(database: database).upsert(target)

        try await ReminderNotificationsToggle.enable(userID: "user-1", database: database, settings: settings, notifications: environment, now: now)

        let scheduled = await center.scheduled
        #expect(scheduled.count == 1)
        let saved = try ReminderRepository(database: database).get(id: target.id)
        #expect(saved?.notificationID == scheduled.first?.id)
        #expect(try settings.reminderNotificationsEnabled() == true)
    }

    @Test("A reminder already carrying an id is cancelled first, never left with two live OS notifications")
    func rewritesAnExistingID() async throws {
        let database = try AppDatabase.inMemory()
        try makeContact(database, userID: "user-1")
        let center = FakeNotificationCenter(status: .authorized)
        let environment = makeEnvironment(database, center: center)
        let settings = AppSettingsStore(database: database)

        let target = reminder(contactID: "c1", remindAt: future(), notificationID: "stale-id")
        try ReminderRepository(database: database).upsert(target)

        try await ReminderNotificationsToggle.enable(userID: "user-1", database: database, settings: settings, notifications: environment, now: now)

        let removedCalls = await center.removedIDCalls
        #expect(removedCalls.contains(["stale-id"]))
        let saved = try ReminderRepository(database: database).get(id: target.id)
        #expect(saved?.notificationID != nil)
        #expect(saved?.notificationID != "stale-id")
    }

    @Test("Never schedules the tutorial reminder, even though it is .scheduled")
    func neverSchedulesTheTutorialReminder() async throws {
        let database = try AppDatabase.inMemory()
        try makeContact(database, userID: "user-1")
        let center = FakeNotificationCenter(status: .authorized)
        let environment = makeEnvironment(database, center: center)
        let settings = AppSettingsStore(database: database)
        try settings.setRawValue(.onboardingTutorialReminderID, "tutorial-1")

        let tutorial = reminder(id: "tutorial-1", contactID: "c1", remindAt: future())
        let ordinary = reminder(contactID: "c1", remindAt: future())
        try ReminderRepository(database: database).upsert(tutorial)
        try ReminderRepository(database: database).upsert(ordinary)

        try await ReminderNotificationsToggle.enable(userID: "user-1", database: database, settings: settings, notifications: environment, now: now)

        let scheduled = await center.scheduled
        #expect(scheduled.count == 1)
        #expect(try ReminderRepository(database: database).get(id: "tutorial-1")?.notificationID == nil)
        #expect(try ReminderRepository(database: database).get(id: ordinary.id)?.notificationID != nil)
    }
}
