import Foundation

/// Deterministic Home-screen contact ranking. Ports
/// packages/shared/src/ranking/ranking.ts and the section dedupe in
/// apps/mobile/src/features/home/homeListModel.ts.
public enum HomeRanking {
    /// A contact ranked into the Upcoming section, decorated with the
    /// reminder that ranked it. Mirrors `UpcomingContact` in ranking.ts.
    public struct UpcomingContact: Equatable, Sendable {
        public var contact: Contact
        public var reminderTitle: String
        public var reminderRemindAt: String

        public init(contact: Contact, reminderTitle: String, reminderRemindAt: String) {
            self.contact = contact
            self.reminderTitle = reminderTitle
            self.reminderRemindAt = reminderRemindAt
        }
    }

    /// The three Home sections after each contact has been claimed by at
    /// most one of them. See `dedupeHomeSections`.
    public struct HomeSections: Equatable, Sendable {
        public var recent: [Contact]
        public var upcoming: [UpcomingContact]
        public var reconnect: [Contact]

        public init(recent: [Contact], upcoming: [UpcomingContact], reconnect: [Contact]) {
            self.recent = recent
            self.upcoming = upcoming
            self.reconnect = reconnect
        }
    }

    /// Orders contacts by most recent interaction for the Home "Recently"
    /// section. Contacts stale enough to qualify for Reconnect are
    /// excluded — so a contact never shows under two subtitles describing
    /// the same fact — and contacts with no interaction yet (freshly added,
    /// never contacted) are kept, since dropping them would empty Recently
    /// for a brand-new user who just added contacts.
    ///
    /// - Parameters:
    ///   - reconnectDaysThreshold: Must match the threshold passed to
    ///     `rankReconnect` for the same call, or a contact could appear in
    ///     both sections.
    ///   - limit: Maximum contacts returned. Ports `rankRecentContacts`.
    public static func rankRecent(
        _ contacts: [Contact],
        nowISO: String,
        reconnectDaysThreshold: Double = 60,
        limit: Int = 20
    ) -> [Contact] {
        guard let now = ReloraTimestamp.parse(nowISO)?.timeIntervalSince1970 else {
            return []
        }

        let ranked = contacts
            .filter { contact in
                if contact.deletedAt != nil {
                    return false
                }
                guard let lastInteractionAt = contact.lastInteractionAt,
                      let lastInteractionDate = ReloraTimestamp.parse(lastInteractionAt) else {
                    return true
                }
                let ageDays = (now - lastInteractionDate.timeIntervalSince1970) / 86_400
                return ageDays < reconnectDaysThreshold
            }
            .sorted { lhs, rhs in
                (lhs.lastInteractionAt ?? "") > (rhs.lastInteractionAt ?? "")
            }

        return Array(ranked.prefix(limit))
    }

    /// Orders contacts by their next future scheduled reminder, keeping
    /// that reminder alongside. Unlike `rankRecent`, the RN source applies
    /// no cap here — see the module-level note in the M1 handoff report.
    /// Ports `rankUpcomingContacts`.
    public static func rankUpcoming(
        _ contacts: [Contact],
        reminders: [Reminder],
        nowISO: String = ReloraTimestamp.now()
    ) -> [UpcomingContact] {
        guard let nowMs = ReloraTimestamp.parse(nowISO)?.timeIntervalSince1970 else {
            return []
        }

        func isFutureScheduledReminder(_ reminder: Reminder) -> Bool {
            guard reminder.status == .scheduled, reminder.deletedAt == nil else {
                return false
            }
            guard let remindAtMs = ReloraTimestamp.parse(reminder.remindAt)?.timeIntervalSince1970 else {
                return false
            }
            return remindAtMs > nowMs
        }

        var nextByContact: [String: Reminder] = [:]
        let futureReminders = reminders
            .filter(isFutureScheduledReminder)
            .sorted { $0.remindAt < $1.remindAt }
        for reminder in futureReminders where nextByContact[reminder.contactID] == nil {
            nextByContact[reminder.contactID] = reminder
        }

        let rankedContacts = contacts
            .filter { $0.deletedAt == nil && nextByContact[$0.id] != nil }
            .sorted { lhs, rhs in
                (nextByContact[lhs.id]?.remindAt ?? "") < (nextByContact[rhs.id]?.remindAt ?? "")
            }

        return rankedContacts.map { contact in
            let reminder = nextByContact[contact.id]!
            return UpcomingContact(
                contact: contact,
                reminderTitle: reminder.title,
                reminderRemindAt: reminder.remindAt
            )
        }
    }

    /// Orders contacts whose last interaction is older than
    /// `reconnectDaysThreshold`, oldest first. Ports
    /// `rankReconnectContacts`; the RN source applies no cap here either —
    /// see the module-level note in the M1 handoff report.
    public static func rankReconnect(
        _ contacts: [Contact],
        nowISO: String,
        reconnectDaysThreshold: Double = 60
    ) -> [Contact] {
        guard let now = ReloraTimestamp.parse(nowISO)?.timeIntervalSince1970 else {
            return []
        }

        return contacts
            .filter { contact in
                guard let lastInteractionAt = contact.lastInteractionAt, contact.deletedAt == nil else {
                    return false
                }
                guard let lastInteractionDate = ReloraTimestamp.parse(lastInteractionAt) else {
                    return false
                }
                let ageDays = (now - lastInteractionDate.timeIntervalSince1970) / 86_400
                return ageDays >= reconnectDaysThreshold
            }
            .sorted { lhs, rhs in
                let lhsMs = lhs.lastInteractionAt.flatMap(ReloraTimestamp.parse)?.timeIntervalSince1970 ?? 0
                let rhsMs = rhs.lastInteractionAt.flatMap(ReloraTimestamp.parse)?.timeIntervalSince1970 ?? 0
                return lhsMs < rhsMs
            }
    }

    /// Claims each contact for exactly one Home section, in priority order
    /// Upcoming > Recently > Reconnect, mirroring the dedupe in
    /// `buildHomeListItems` (apps/mobile/src/features/home/homeListModel.ts).
    /// A contact ranked into more than one section — e.g. a stale contact
    /// with a reminder coming up — keeps only its highest-priority section
    /// and is dropped from the rest, so it is never listed twice.
    public static func dedupeHomeSections(
        recent: [Contact],
        upcoming: [UpcomingContact],
        reconnect: [Contact]
    ) -> HomeSections {
        var claimed: Set<String> = []

        func claim(_ id: String) -> Bool {
            if claimed.contains(id) {
                return false
            }
            claimed.insert(id)
            return true
        }

        let claimedUpcoming = upcoming.filter { claim($0.contact.id) }
        let claimedRecent = recent.filter { claim($0.id) }
        let claimedReconnect = reconnect.filter { claim($0.id) }

        return HomeSections(recent: claimedRecent, upcoming: claimedUpcoming, reconnect: claimedReconnect)
    }
}
