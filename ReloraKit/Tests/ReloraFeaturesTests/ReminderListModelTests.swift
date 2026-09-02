import Foundation
import Testing
import ReloraCore
@testable import ReloraFeatures

// MARK: - Fixtures

private let fixedNowISO = "2026-08-31T12:00:00.000Z"

private func reminder(
    _ id: String = ReloraID.new(),
    contactID: String = "contact-1",
    title: String = "Follow up",
    remindAt: String = fixedNowISO,
    status: ReminderStatus = .scheduled,
    updatedAt: String = fixedNowISO,
    deletedAt: String? = nil
) -> Reminder {
    Reminder(
        id: id,
        contactID: contactID,
        userID: "user-1",
        title: title,
        remindAt: remindAt,
        status: status,
        createdAt: fixedNowISO,
        updatedAt: updatedAt,
        deletedAt: deletedAt
    )
}

// MARK: - classify

@Suite("ReminderListModel.classify")
struct ReminderListModelClassifyTests {
    @Test("A dismissed reminder is done regardless of remindAt, past or future")
    func dismissedIsAlwaysDone() {
        let past = reminder(remindAt: "2020-01-01T00:00:00.000Z", status: .dismissed)
        let future = reminder(remindAt: "2099-01-01T00:00:00.000Z", status: .dismissed)
        #expect(ReminderListModel.classify(past, nowISO: fixedNowISO) == .done)
        #expect(ReminderListModel.classify(future, nowISO: fixedNowISO) == .done)
    }

    @Test("A fired reminder is also done, the same as dismissed")
    func firedIsDone() {
        #expect(ReminderListModel.classify(reminder(status: .fired), nowISO: fixedNowISO) == .done)
    }

    @Test("A scheduled reminder due exactly now is overdue, not upcoming — the <= boundary matches ReminderBadge")
    func exactlyNowIsOverdue() {
        #expect(ReminderListModel.classify(reminder(remindAt: fixedNowISO), nowISO: fixedNowISO) == .overdue)
    }

    @Test("A scheduled reminder a second in the past is overdue")
    func pastIsOverdue() {
        let secondAgo = reminder(remindAt: "2026-08-31T11:59:59.000Z")
        #expect(ReminderListModel.classify(secondAgo, nowISO: fixedNowISO) == .overdue)
    }

    @Test("A scheduled reminder a second in the future is upcoming")
    func futureIsUpcoming() {
        let secondFromNow = reminder(remindAt: "2026-08-31T12:00:01.000Z")
        #expect(ReminderListModel.classify(secondFromNow, nowISO: fixedNowISO) == .upcoming)
    }

    @Test("An unparseable remindAt reads as upcoming rather than claiming to be overdue")
    func unparseableIsUpcoming() {
        #expect(ReminderListModel.classify(reminder(remindAt: "not-a-date"), nowISO: fixedNowISO) == .upcoming)
    }
}

// MARK: - sections

@Suite("ReminderListModel.sections")
struct ReminderListModelSectionsTests {
    @Test("Soft-deleted reminders never appear in any section")
    func excludesTombstoned() {
        let live = reminder(title: "Live")
        let deleted = reminder(title: "Deleted", deletedAt: "2026-08-30T00:00:00.000Z")
        let sections = ReminderListModel.sections(reminders: [live, deleted], contactNames: [:], nowISO: fixedNowISO)
        let allTitles = sections.flatMap { $0.rows.map(\.reminder.title) }
        #expect(allTitles == ["Live"])
    }

    @Test("Sections appear only when non-empty, in Overdue, Upcoming, Done order")
    func onlyNonEmptySectionsInFixedOrder() {
        let overdue = reminder(title: "Overdue one", remindAt: "2020-01-01T00:00:00.000Z")
        let done = reminder(title: "Done one", status: .dismissed)
        // No upcoming reminder in this set.
        let sections = ReminderListModel.sections(
            reminders: [done, overdue],
            contactNames: [:],
            nowISO: fixedNowISO
        )
        #expect(sections.map(\.bucket) == [.overdue, .done])
    }

    @Test("Overdue and upcoming sort soonest-first by remindAt")
    func overdueAndUpcomingSortAscending() {
        let laterOverdue = reminder(title: "Later overdue", remindAt: "2026-08-31T10:00:00.000Z")
        let soonerOverdue = reminder(title: "Sooner overdue", remindAt: "2026-08-31T08:00:00.000Z")
        let laterUpcoming = reminder(title: "Later upcoming", remindAt: "2026-09-05T00:00:00.000Z")
        let soonerUpcoming = reminder(title: "Sooner upcoming", remindAt: "2026-09-01T00:00:00.000Z")

        let sections = ReminderListModel.sections(
            reminders: [laterOverdue, soonerOverdue, laterUpcoming, soonerUpcoming],
            contactNames: [:],
            nowISO: fixedNowISO
        )

        let overdueTitles = sections.first { $0.bucket == .overdue }?.rows.map(\.reminder.title)
        let upcomingTitles = sections.first { $0.bucket == .upcoming }?.rows.map(\.reminder.title)
        #expect(overdueTitles == ["Sooner overdue", "Later overdue"])
        #expect(upcomingTitles == ["Sooner upcoming", "Later upcoming"])
    }

    @Test("Done sorts most-recently-completed first, by descending updatedAt")
    func doneSortsDescendingByUpdatedAt() {
        let completedEarlier = reminder(title: "Completed earlier", status: .dismissed, updatedAt: "2026-08-30T00:00:00.000Z")
        let completedLater = reminder(title: "Completed later", status: .dismissed, updatedAt: "2026-08-31T00:00:00.000Z")

        let sections = ReminderListModel.sections(
            reminders: [completedEarlier, completedLater],
            contactNames: [:],
            nowISO: fixedNowISO
        )
        #expect(sections.first?.rows.map(\.reminder.title) == ["Completed later", "Completed earlier"])
    }

    @Test("A reminder whose contact has no live row is dropped, matching RN")
    func missingContactDropsRow() {
        let sections = ReminderListModel.sections(
            reminders: [reminder(contactID: "unknown-contact")],
            contactNames: ["contact-1": "Ada"],
            nowISO: fixedNowISO
        )
        #expect(sections.isEmpty)
    }

    @Test("overdueNote is set only on rows in the overdue bucket")
    func overdueNoteOnlyOnOverdueRows() {
        let overdue = reminder(title: "Overdue", remindAt: "2020-01-01T00:00:00.000Z")
        let upcoming = reminder(title: "Upcoming", remindAt: "2099-01-01T00:00:00.000Z")
        let done = reminder(title: "Done", status: .dismissed)

        let sections = ReminderListModel.sections(
            reminders: [overdue, upcoming, done],
            contactNames: [:],
            nowISO: fixedNowISO
        )

        #expect(sections.first { $0.bucket == .overdue }?.rows.first?.overdueNote != nil)
        #expect(sections.first { $0.bucket == .upcoming }?.rows.first?.overdueNote == nil)
        #expect(sections.first { $0.bucket == .done }?.rows.first?.overdueNote == nil)
    }
}
