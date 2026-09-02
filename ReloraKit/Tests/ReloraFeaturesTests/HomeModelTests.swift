import Foundation
import Testing
import ReloraCore
import ReloraSync
@testable import ReloraFeatures

// MARK: - Fixtures

private let now = "2026-08-31T12:00:00.000Z"

private func iso(daysFromNow days: Double) -> String {
    let base = ReloraTimestamp.parse(now)!
    return ReloraTimestamp.from(base.addingTimeInterval(days * 86_400))
}

private func contact(
    _ id: String,
    name: String,
    lastInteractionAt: String? = nil,
    phone: String? = nil,
    email: String? = nil,
    descriptors: [String] = [],
    updatedAt: String = now
) -> Contact {
    Contact(
        id: id,
        userID: "user-1",
        name: name,
        descriptors: descriptors,
        phoneNumber: phone,
        email: email,
        createdAt: now,
        updatedAt: updatedAt,
        lastInteractionAt: lastInteractionAt
    )
}

private func reminder(
    _ id: String,
    contactID: String,
    title: String = "Send the deck",
    remindAt: String,
    status: ReminderStatus = .scheduled
) -> Reminder {
    Reminder(
        id: id,
        contactID: contactID,
        userID: "user-1",
        title: title,
        remindAt: remindAt,
        status: status,
        createdAt: now,
        updatedAt: now
    )
}

// MARK: - Sections

@Suite("Home sections")
struct HomeListModelTests {
    /// Claim order and display order are different, and both matter. Upcoming
    /// claims a contact first; Recently is drawn first.
    @Test("Sections are drawn Recently, Upcoming, Reconnect")
    func displayOrder() {
        let recent = contact("c1", name: "Ana", lastInteractionAt: iso(daysFromNow: -2))
        let upcoming = contact("c2", name: "Ben", lastInteractionAt: iso(daysFromNow: -3))
        let stale = contact("c3", name: "Cy", lastInteractionAt: iso(daysFromNow: -120))

        let sections = HomeListModel.build(
            contacts: [stale, upcoming, recent],
            reminders: [reminder("r1", contactID: "c2", remindAt: iso(daysFromNow: 1))],
            nowISO: now
        )

        #expect(sections.map(\.title) == ["Recently", "Upcoming", "Reconnect"])
        #expect(sections[0].rows.map(\.contact.id) == ["c1"])
        #expect(sections[1].rows.map(\.contact.id) == ["c2"])
        #expect(sections[2].rows.map(\.contact.id) == ["c3"])
    }

    @Test("A contact with a reminder is claimed by Upcoming, and appears once")
    func claimOrder() {
        let person = contact("c1", name: "Ana", lastInteractionAt: iso(daysFromNow: -1))

        let sections = HomeListModel.build(
            contacts: [person],
            reminders: [reminder("r1", contactID: "c1", remindAt: iso(daysFromNow: 2))],
            nowISO: now
        )

        #expect(sections.map(\.title) == ["Upcoming"])
        #expect(sections.flatMap(\.rows).count == 1)
    }

    @Test("Empty sections are left out entirely")
    func emptySectionsOmitted() {
        let sections = HomeListModel.build(contacts: [], reminders: [], nowISO: now)
        #expect(sections.isEmpty)
    }

    @Test("Subtitles say what each section means")
    func subtitles() {
        let recent = contact("c1", name: "Ana", lastInteractionAt: iso(daysFromNow: -3))
        let stale = contact("c2", name: "Cy", lastInteractionAt: iso(daysFromNow: -120))

        let sections = HomeListModel.build(
            contacts: [recent, stale],
            reminders: [],
            nowISO: now
        )

        #expect(sections[0].rows[0].subtitle == "Last note 3 days ago")
        #expect(sections[1].rows[0].subtitle?.hasPrefix("No contact in ") == true)
    }

    @Test("An upcoming row pairs the reminder with when it lands")
    func upcomingSubtitle() {
        let person = contact("c1", name: "Ana", lastInteractionAt: iso(daysFromNow: -1))
        let sections = HomeListModel.build(
            contacts: [person],
            reminders: [reminder("r1", contactID: "c1", remindAt: iso(daysFromNow: 1))],
            nowISO: now
        )

        #expect(sections[0].rows[0].subtitle == "Send the deck · tomorrow")
    }

    /// An unparseable timestamp produces no subtitle rather than a wrong one.
    @Test("A broken timestamp yields no subtitle")
    func brokenTimestamp() {
        let person = contact("c1", name: "Ana", lastInteractionAt: "not-a-date")
        let rows = HomeListModel.searchSection(results: [person], snippets: [:], nowISO: now).rows
        #expect(rows[0].subtitle == nil)
    }

    @Test("Search prefers the matched words over the last-note date")
    func searchSnippetWins() {
        let person = contact("c1", name: "Ana", lastInteractionAt: iso(daysFromNow: -1))
        let section = HomeListModel.searchSection(
            results: [person],
            snippets: ["c1": "…climbs on weekends…"],
            nowISO: now
        )

        #expect(section.title == "Search Results")
        #expect(section.rows[0].subtitle == "…climbs on weekends…")
    }

    @Test("VoiceOver reads the row as one phrase")
    func rowAccessibilityLabel() {
        let row = HomeContactRow(contact: contact("c1", name: "Ana"), subtitle: "Last note 3 days ago")
        #expect(row.accessibilityLabel == "Ana, Last note 3 days ago")

        let bare = HomeContactRow(contact: contact("c1", name: "Ana"), subtitle: nil)
        #expect(bare.accessibilityLabel == "Ana")
    }
}

// MARK: - Banner precedence

@Suite("Home banner")
struct HomeBannerStateTests {
    /// One banner at a time, in this order. Three stacked warnings about the
    /// same underlying problem is noise, and the most actionable one wins.
    @Test("Migration outranks offline, which outranks a failed sync")
    func precedence() {
        #expect(
            HomeBannerState.banner(ownershipMigrationPending: true, isOnline: false, syncStatus: .failed)
                == .migrationPending
        )
        #expect(
            HomeBannerState.banner(ownershipMigrationPending: false, isOnline: false, syncStatus: .failed)
                == .offline
        )
        #expect(
            HomeBannerState.banner(ownershipMigrationPending: false, isOnline: true, syncStatus: .failed)
                == .syncFailed
        )
    }

    @Test("A healthy app shows no banner")
    func healthy() {
        #expect(
            HomeBannerState.banner(ownershipMigrationPending: false, isOnline: true, syncStatus: .idle) == nil
        )
        #expect(
            HomeBannerState.banner(ownershipMigrationPending: false, isOnline: true, syncStatus: .syncing) == nil
        )
    }

    /// Retry is offered only where pressing it can change something. Nothing the
    /// app does makes a network appear.
    @Test("Offline offers no retry; the other two do")
    func retryability() {
        #expect(HomeBanner.offline.isRetryable == false)
        #expect(HomeBanner.migrationPending.isRetryable)
        #expect(HomeBanner.syncFailed.isRetryable)
    }
}

// MARK: - Reminder badge

@Suite("Reminder badge")
struct ReminderBadgeTests {
    @Test("Only scheduled reminders in the past count as overdue")
    func overdueCount() {
        let reminders = [
            reminder("r1", contactID: "c1", remindAt: iso(daysFromNow: -1)),
            reminder("r2", contactID: "c1", remindAt: iso(daysFromNow: 1)),
            reminder("r3", contactID: "c1", remindAt: iso(daysFromNow: -2), status: .dismissed),
            reminder("r4", contactID: "c1", remindAt: "not-a-date")
        ]

        #expect(ReminderBadge.overdueCount(reminders, nowISO: now) == 1)
    }

    @Test("The badge caps at 9+ and disappears at zero")
    func badgeText() {
        #expect(ReminderBadge.badgeText(0) == nil)
        #expect(ReminderBadge.badgeText(1) == "1")
        #expect(ReminderBadge.badgeText(9) == "9")
        #expect(ReminderBadge.badgeText(10) == "9+")
    }

    @Test("VoiceOver hears the real count, not the capped one")
    func accessibilityLabel() {
        #expect(ReminderBadge.accessibilityLabel(0) == "Open reminders")
        #expect(ReminderBadge.accessibilityLabel(12) == "Open reminders, 12 overdue")
    }
}
