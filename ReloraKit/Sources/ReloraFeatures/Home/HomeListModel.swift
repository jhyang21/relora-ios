import Foundation
import ReloraCore

/// One contact as Home lists it.
public struct HomeContactRow: Identifiable, Equatable, Sendable {
    public var contact: Contact
    /// The second line. `nil` when there is nothing true to say — an unparseable
    /// timestamp produces no subtitle rather than a guess.
    public var subtitle: String?

    public var id: String { contact.id }

    /// What VoiceOver reads. Ports the row label in `HomeScreen.tsx`: name, then
    /// the subtitle as one phrase, so the list can be swiped through without
    /// every row costing two stops.
    public var accessibilityLabel: String {
        guard let subtitle, !subtitle.isEmpty else { return contact.name }
        return "\(contact.name), \(subtitle)"
    }
}

public struct HomeSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var rows: [HomeContactRow]
}

/// Turns ranked contacts into the rows Home draws.
///
/// Ports `buildHomeListItems` (apps/mobile/src/features/home/homeListModel.ts).
/// Pure, so the subtitle wording and the section ordering can be tested without
/// a database or a view.
public enum HomeListModel {

    // MARK: Subtitles

    /// "Last note 3 days ago".
    static func lastInteractionSubtitle(_ contact: Contact, nowISO: String) -> String? {
        guard let lastInteractionAt = contact.lastInteractionAt else { return nil }
        let relative = ReloraRelativeTime.relative(lastInteractionAt, now: nowISO)
        return relative.isEmpty ? nil : "Last note \(relative)"
    }

    /// "No contact in 8 weeks".
    static func reconnectSubtitle(_ contact: Contact, nowISO: String) -> String? {
        guard let lastInteractionAt = contact.lastInteractionAt else { return nil }
        let duration = ReloraRelativeTime.duration(from: lastInteractionAt, to: nowISO)
        return duration.isEmpty ? nil : "No contact in \(duration)"
    }

    /// "Send the deck · tomorrow". Falls back to the bare title when the time
    /// cannot be phrased, because the reminder's own words still carry meaning.
    static func upcomingSubtitle(_ entry: HomeRanking.UpcomingContact, nowISO: String) -> String? {
        let relative = ReloraRelativeTime.relative(entry.reminderRemindAt, now: nowISO)
        return relative.isEmpty ? entry.reminderTitle : "\(entry.reminderTitle) · \(relative)"
    }

    // MARK: Sections

    /// The search-results section.
    ///
    /// The subtitle prefers the FTS snippet — the words that actually matched —
    /// over the last-note date. Someone who searched "climbing" wants to see
    /// where "climbing" appears, not when they last spoke.
    public static func searchSection(
        results: [Contact],
        snippets: [String: String],
        nowISO: String
    ) -> HomeSection {
        HomeSection(
            id: "search",
            title: "Search Results",
            rows: results.map { contact in
                HomeContactRow(
                    contact: contact,
                    subtitle: snippets[contact.id] ?? lastInteractionSubtitle(contact, nowISO: nowISO)
                )
            }
        )
    }

    /// The resting sections, in display order.
    ///
    /// Display order is Recently, Upcoming, Reconnect. **Claim order is
    /// different** — Upcoming claims a contact first, then Recently, then
    /// Reconnect — and that ordering lives in
    /// `HomeRanking.dedupeHomeSections`, whose output this takes. Passing
    /// un-deduped rankings here would list a contact twice.
    public static func sections(
        from sections: HomeRanking.HomeSections,
        nowISO: String
    ) -> [HomeSection] {
        var built: [HomeSection] = []

        if !sections.recent.isEmpty {
            built.append(
                HomeSection(
                    id: "recent",
                    title: "Recently",
                    rows: sections.recent.map {
                        HomeContactRow(contact: $0, subtitle: lastInteractionSubtitle($0, nowISO: nowISO))
                    }
                )
            )
        }

        if !sections.upcoming.isEmpty {
            built.append(
                HomeSection(
                    id: "upcoming",
                    title: "Upcoming",
                    rows: sections.upcoming.map {
                        HomeContactRow(contact: $0.contact, subtitle: upcomingSubtitle($0, nowISO: nowISO))
                    }
                )
            )
        }

        if !sections.reconnect.isEmpty {
            built.append(
                HomeSection(
                    id: "reconnect",
                    title: "Reconnect",
                    rows: sections.reconnect.map {
                        HomeContactRow(contact: $0, subtitle: reconnectSubtitle($0, nowISO: nowISO))
                    }
                )
            )
        }

        return built
    }

    /// Ranks and sections in one call, the way Home consumes it.
    public static func build(
        contacts: [Contact],
        reminders: [Reminder],
        nowISO: String
    ) -> [HomeSection] {
        let deduped = HomeRanking.dedupeHomeSections(
            recent: HomeRanking.rankRecent(contacts, nowISO: nowISO),
            upcoming: HomeRanking.rankUpcoming(contacts, reminders: reminders, nowISO: nowISO),
            reconnect: HomeRanking.rankReconnect(contacts, nowISO: nowISO)
        )
        return sections(from: deduped, nowISO: nowISO)
    }
}
