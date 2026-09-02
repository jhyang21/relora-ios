import Testing
@testable import ReloraCore

@Suite("HomeRanking")
struct RankingTests {
    private static func makeContact(
        id: String = "11111111-1111-1111-1111-111111111111",
        name: String = "A",
        lastInteractionAt: String? = "2026-01-01T00:00:00.000Z",
        deletedAt: String? = nil
    ) -> Contact {
        Contact(
            id: id,
            userID: "22222222-2222-2222-2222-222222222222",
            name: name,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z",
            lastInteractionAt: lastInteractionAt,
            deletedAt: deletedAt
        )
    }

    private static func makeReminder(
        contactID: String = "11111111-1111-1111-1111-111111111111",
        title: String = "Follow up",
        remindAt: String = "2026-03-10T10:00:00.000Z",
        status: ReminderStatus = .scheduled,
        deletedAt: String? = nil
    ) -> Reminder {
        Reminder(
            id: "33333333-3333-3333-3333-333333333333",
            contactID: contactID,
            userID: "22222222-2222-2222-2222-222222222222",
            title: title,
            remindAt: remindAt,
            status: status,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z",
            deletedAt: deletedAt
        )
    }

    // MARK: rankRecent

    @Test("ranks recent contacts by most recent interaction")
    func ranksByMostRecentInteraction() {
        let result = HomeRanking.rankRecent(
            [
                Self.makeContact(id: "1", name: "Older", lastInteractionAt: "2026-01-20T00:00:00.000Z"),
                Self.makeContact(id: "2", name: "Newer", lastInteractionAt: "2026-02-01T00:00:00.000Z"),
            ],
            nowISO: "2026-02-16T00:00:00.000Z"
        )
        #expect(result.map(\.name) == ["Newer", "Older"])
    }

    @Test("excludes contacts that qualify for Reconnect so a contact never appears in both sections")
    func excludesReconnectEligibleContacts() {
        let result = HomeRanking.rankRecent(
            [
                Self.makeContact(id: "1", name: "Fresh", lastInteractionAt: "2026-02-10T00:00:00.000Z"),
                Self.makeContact(id: "2", name: "Stale", lastInteractionAt: "2025-11-01T00:00:00.000Z"),
            ],
            nowISO: "2026-02-16T00:00:00.000Z",
            reconnectDaysThreshold: 60
        )
        #expect(result.map(\.name) == ["Fresh"])
    }

    @Test("keeps never-contacted contacts so a brand-new user does not see an empty Recently")
    func keepsNeverContactedContacts() {
        let result = HomeRanking.rankRecent(
            [Self.makeContact(id: "1", name: "New", lastInteractionAt: nil)],
            nowISO: "2026-02-16T00:00:00.000Z"
        )
        #expect(result.map(\.name) == ["New"])
    }

    @Test("excludes deleted contacts")
    func excludesDeletedContacts() {
        let result = HomeRanking.rankRecent(
            [Self.makeContact(
                id: "1",
                name: "Deleted",
                lastInteractionAt: "2026-02-10T00:00:00.000Z",
                deletedAt: "2026-02-11T00:00:00.000Z"
            )],
            nowISO: "2026-02-16T00:00:00.000Z"
        )
        #expect(result.isEmpty)
    }

    @Test("caps the number of recent contacts to the configured limit")
    func capsToConfiguredLimit() {
        let contacts = (0..<5).map { index in
            Self.makeContact(
                id: String(index),
                name: "Contact \(index)",
                lastInteractionAt: "2026-02-\(String(format: "%02d", 10 + index))T00:00:00.000Z"
            )
        }
        let result = HomeRanking.rankRecent(contacts, nowISO: "2026-02-16T00:00:00.000Z", limit: 2)
        #expect(result.map(\.name) == ["Contact 4", "Contact 3"])
    }

    @Test("uses the default reconnect threshold (60 days) when not overridden")
    func usesDefaultReconnectThreshold() {
        let justUnder = HomeRanking.rankRecent(
            [Self.makeContact(id: "1", name: "JustUnder", lastInteractionAt: "2025-12-19T00:00:00.000Z")],
            nowISO: "2026-02-16T00:00:00.000Z"
        )
        #expect(justUnder.map(\.name) == ["JustUnder"])

        let atThreshold = HomeRanking.rankRecent(
            [Self.makeContact(id: "1", name: "AtThreshold", lastInteractionAt: "2025-12-18T00:00:00.000Z")],
            nowISO: "2026-02-16T00:00:00.000Z"
        )
        #expect(atThreshold.isEmpty)
    }

    // MARK: rankUpcoming

    @Test("ranks upcoming contacts by earliest scheduled reminder and exposes that reminder")
    func ranksUpcomingByEarliestReminder() {
        let contacts = [Self.makeContact(id: "1", name: "A"), Self.makeContact(id: "2", name: "B")]
        let reminders = [
            Self.makeReminder(contactID: "2", remindAt: "2026-03-11T10:00:00.000Z"),
            Self.makeReminder(contactID: "1", title: "Send the deck", remindAt: "2026-03-10T10:00:00.000Z"),
            Self.makeReminder(contactID: "1", title: "Later follow-up", remindAt: "2026-03-20T10:00:00.000Z"),
        ]
        let result = HomeRanking.rankUpcoming(contacts, reminders: reminders, nowISO: "2026-03-05T00:00:00.000Z")

        #expect(result.map { $0.contact.id } == ["1", "2"])
        #expect(result.first?.reminderTitle == "Send the deck")
        #expect(result.first?.reminderRemindAt == "2026-03-10T10:00:00.000Z")
    }

    @Test("ignores dismissed or deleted reminders when building upcoming contacts")
    func ignoresDismissedOrDeletedReminders() {
        let contacts = [Self.makeContact(id: "1", name: "A"), Self.makeContact(id: "2", name: "B")]
        let reminders = [
            Self.makeReminder(contactID: "1", status: .dismissed, remindAt: "2026-03-09T10:00:00.000Z"),
            Self.makeReminder(contactID: "1", remindAt: "2026-03-10T10:00:00.000Z"),
            Self.makeReminder(contactID: "2", remindAt: "2026-03-08T10:00:00.000Z", deletedAt: "2026-03-01T00:00:00.000Z"),
        ]
        let result = HomeRanking.rankUpcoming(contacts, reminders: reminders, nowISO: "2026-03-05T00:00:00.000Z")

        #expect(result.map { $0.contact.id } == ["1"])
        #expect(result.first?.reminderRemindAt == "2026-03-10T10:00:00.000Z")
    }

    @Test("ignores past-due scheduled reminders when building upcoming contacts")
    func ignoresPastDueReminders() {
        let contacts = [Self.makeContact(id: "1", name: "A"), Self.makeContact(id: "2", name: "B")]
        let reminders = [
            Self.makeReminder(contactID: "1", remindAt: "2026-03-01T10:00:00.000Z"),
            Self.makeReminder(contactID: "2", remindAt: "2026-03-10T10:00:00.000Z"),
        ]
        let result = HomeRanking.rankUpcoming(contacts, reminders: reminders, nowISO: "2026-03-05T00:00:00.000Z")

        #expect(result.map { $0.contact.id } == ["2"])
    }

    // MARK: rankReconnect

    @Test("returns reconnect contacts older than threshold")
    func returnsReconnectContactsOlderThanThreshold() {
        let result = HomeRanking.rankReconnect(
            [
                Self.makeContact(id: "1", name: "Fresh", lastInteractionAt: "2026-02-10T00:00:00.000Z"),
                Self.makeContact(id: "2", name: "Stale", lastInteractionAt: "2025-11-01T00:00:00.000Z"),
            ],
            nowISO: "2026-02-16T00:00:00.000Z",
            reconnectDaysThreshold: 60
        )
        #expect(result.map(\.name) == ["Stale"])
    }

    // MARK: dedupeHomeSections

    @Test("claims a contact for Upcoming over Recently and Reconnect when it ranks into all three")
    func dedupeClaimsUpcomingFirst() {
        let shared = Self.makeContact(id: "dup", name: "Dup")
        let upcoming = HomeRanking.UpcomingContact(
            contact: shared,
            reminderTitle: "Call",
            reminderRemindAt: "2026-07-05T12:00:00.000Z"
        )

        let sections = HomeRanking.dedupeHomeSections(
            recent: [shared],
            upcoming: [upcoming],
            reconnect: [shared]
        )

        #expect(sections.upcoming.map { $0.contact.id } == ["dup"])
        #expect(sections.recent.isEmpty)
        #expect(sections.reconnect.isEmpty)
    }

    @Test("keeps every section when the contacts differ")
    func dedupeKeepsAllSectionsForDistinctContacts() {
        let sections = HomeRanking.dedupeHomeSections(
            recent: [Self.makeContact(id: "a")],
            upcoming: [HomeRanking.UpcomingContact(
                contact: Self.makeContact(id: "b"),
                reminderTitle: "Call",
                reminderRemindAt: "2026-07-05T12:00:00.000Z"
            )],
            reconnect: [Self.makeContact(id: "c")]
        )

        #expect(sections.recent.map(\.id) == ["a"])
        #expect(sections.upcoming.map { $0.contact.id } == ["b"])
        #expect(sections.reconnect.map(\.id) == ["c"])
    }
}
