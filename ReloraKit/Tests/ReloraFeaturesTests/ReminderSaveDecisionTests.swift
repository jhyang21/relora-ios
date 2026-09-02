import Foundation
import Testing
import ReloraCore
@testable import ReloraFeatures

@Suite("ReminderScheduling.decide")
struct ReminderSchedulingDecideTests {
    private let now = Date(timeIntervalSince1970: 1_756_641_600) // 2026-08-31T12:00:00Z

    private func iso(_ date: Date) -> String { ReloraTimestamp.from(date) }

    private func reminder(
        id: String = "reminder-1",
        contactID: String = "contact-1",
        title: String = "Follow up",
        remindAt: Date,
        status: ReminderStatus = .scheduled,
        notificationID: String? = nil,
        deletedAt: String? = nil
    ) -> Reminder {
        Reminder(
            id: id,
            contactID: contactID,
            userID: "user-1",
            title: title,
            remindAt: iso(remindAt),
            status: status,
            createdAt: iso(now),
            updatedAt: iso(now),
            notificationID: notificationID,
            deletedAt: deletedAt
        )
    }

    @Test("No existing row, future, enabled — schedules new")
    func newFutureEnabledSchedulesNew() {
        let candidate = reminder(remindAt: now.addingTimeInterval(3_600))
        let decision = ReminderScheduling.decide(existing: nil, candidate: candidate, notificationsEnabled: true, now: now)
        #expect(decision == .scheduleNew)
    }

    @Test("No existing row, notifications disabled — none")
    func newDisabledIsNone() {
        let candidate = reminder(remindAt: now.addingTimeInterval(3_600))
        let decision = ReminderScheduling.decide(existing: nil, candidate: candidate, notificationsEnabled: false, now: now)
        #expect(decision == .none)
    }

    @Test("No existing row, remindAt already past — none")
    func newPastIsNone() {
        let candidate = reminder(remindAt: now.addingTimeInterval(-3_600))
        let decision = ReminderScheduling.decide(existing: nil, candidate: candidate, notificationsEnabled: true, now: now)
        #expect(decision == .none)
    }

    @Test("Existing matches exactly, still future, enabled — keeps the existing notification id")
    func matchingExistingKeeps() {
        let remindAt = now.addingTimeInterval(3_600)
        let existing = reminder(remindAt: remindAt, notificationID: "notif-1")
        let candidate = reminder(remindAt: remindAt)
        let decision = ReminderScheduling.decide(existing: existing, candidate: candidate, notificationsEnabled: true, now: now)
        #expect(decision == .keep(notificationID: "notif-1"))
    }

    @Test("Existing but the time changed — schedules new rather than keeping the stale one")
    func changedTimeSchedulesNew() {
        let existing = reminder(remindAt: now.addingTimeInterval(3_600), notificationID: "notif-1")
        let candidate = reminder(remindAt: now.addingTimeInterval(7_200))
        let decision = ReminderScheduling.decide(existing: existing, candidate: candidate, notificationsEnabled: true, now: now)
        #expect(decision == .scheduleNew)
    }

    @Test("Existing but the title changed — schedules new")
    func changedTitleSchedulesNew() {
        let remindAt = now.addingTimeInterval(3_600)
        let existing = reminder(title: "Old title", remindAt: remindAt, notificationID: "notif-1")
        let candidate = reminder(title: "New title", remindAt: remindAt)
        let decision = ReminderScheduling.decide(existing: existing, candidate: candidate, notificationsEnabled: true, now: now)
        #expect(decision == .scheduleNew)
    }

    @Test("Existing but the contact changed — schedules new")
    func changedContactSchedulesNew() {
        let remindAt = now.addingTimeInterval(3_600)
        let existing = reminder(contactID: "contact-1", remindAt: remindAt, notificationID: "notif-1")
        let candidate = reminder(contactID: "contact-2", remindAt: remindAt)
        let decision = ReminderScheduling.decide(existing: existing, candidate: candidate, notificationsEnabled: true, now: now)
        #expect(decision == .scheduleNew)
    }

    @Test("Existing notification id is an empty string — not treated as scheduled, JS-truthiness parity")
    func emptyStringNotificationIDIsNotScheduled() {
        let remindAt = now.addingTimeInterval(3_600)
        let existing = reminder(remindAt: remindAt, notificationID: "")
        let candidate = reminder(remindAt: remindAt)
        let decision = ReminderScheduling.decide(existing: existing, candidate: candidate, notificationsEnabled: true, now: now)
        #expect(decision == .scheduleNew)
    }

    @Test("Existing row is not .scheduled — not treated as already scheduled, new candidate still schedules")
    func existingNotScheduledStatusSchedulesNew() {
        let remindAt = now.addingTimeInterval(3_600)
        let existing = reminder(remindAt: remindAt, status: .dismissed, notificationID: "notif-1")
        let candidate = reminder(remindAt: remindAt)
        let decision = ReminderScheduling.decide(existing: existing, candidate: candidate, notificationsEnabled: true, now: now)
        #expect(decision == .scheduleNew)
    }

    @Test("Existing row is tombstoned — not treated as already scheduled")
    func existingDeletedSchedulesNew() {
        let remindAt = now.addingTimeInterval(3_600)
        let existing = reminder(remindAt: remindAt, notificationID: "notif-1", deletedAt: iso(now))
        let candidate = reminder(remindAt: remindAt)
        let decision = ReminderScheduling.decide(existing: existing, candidate: candidate, notificationsEnabled: true, now: now)
        #expect(decision == .scheduleNew)
    }

    @Test("Candidate not future and existing was scheduled — none, not keep")
    func candidateNotFutureIsNoneEvenWithMatchingExisting() {
        let pastRemindAt = now.addingTimeInterval(-3_600)
        let existing = reminder(remindAt: pastRemindAt, notificationID: "notif-1")
        let candidate = reminder(remindAt: pastRemindAt)
        let decision = ReminderScheduling.decide(existing: existing, candidate: candidate, notificationsEnabled: true, now: now)
        #expect(decision == .none)
    }
}
