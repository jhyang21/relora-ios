import Foundation
import ReloraCore

/// The three buckets the reminders screen sorts into. Ports `classifyReminder`
/// / `groupReminders` from `apps/mobile/src/features/reminders/reminderListModel.ts`.
public enum ReminderBucket: String, Identifiable, Sendable, CaseIterable {
    case overdue
    case upcoming
    case done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overdue: return "Overdue"
        case .upcoming: return "Upcoming"
        case .done: return "Done"
        }
    }
}

/// One row, pre-formatted so the view does no date arithmetic of its own.
public struct ReminderRow: Identifiable, Equatable, Sendable {
    public var reminder: Reminder
    public var contactName: String
    /// "{contactName} · {formattedTime}".
    public var metaLine: String
    /// "Overdue · {relative}", set only for a row in the `.overdue` bucket.
    public var overdueNote: String?

    public var id: String { reminder.id }
}

public struct ReminderSection: Identifiable, Equatable, Sendable {
    public var bucket: ReminderBucket
    public var rows: [ReminderRow]

    public var id: String { bucket.id }
}

/// Turns reminder rows into the sections the screen draws. Pure — same
/// reminders, contacts and clock always produce the same sections — so the
/// bucketing and wording are testable without a database or a view.
public enum ReminderListModel {

    /// A dismissed reminder is `.done` regardless of its `remindAt`. A live
    /// one is `.overdue` at and past its own moment (`<=`, matching
    /// `ReminderBadge.overdueCount`) and `.upcoming` before it. An
    /// unparseable `remindAt` reads as upcoming — the same "cannot say when,
    /// so cannot claim to be late" stance `ReminderBadge` takes for overdue,
    /// applied here to keep it out of a bucket it cannot honestly claim.
    public static func classify(_ reminder: Reminder, nowISO: String) -> ReminderBucket {
        guard reminder.status == .scheduled else { return .done }
        guard let remindAt = ReloraTimestamp.parse(reminder.remindAt),
              let now = ReloraTimestamp.parse(nowISO) else {
            return .upcoming
        }
        return remindAt <= now ? .overdue : .upcoming
    }

    static func metaLine(_ reminder: Reminder, contactName: String, nowISO: String) -> String {
        let time = ReloraRelativeTime.friendlyDateTime(reminder.remindAt, now: nowISO)
        return time.isEmpty ? contactName : "\(contactName) · \(time)"
    }

    static func overdueNote(_ reminder: Reminder, nowISO: String) -> String {
        let relative = ReloraRelativeTime.relative(reminder.remindAt, now: nowISO)
        return relative.isEmpty ? "Overdue" : "Overdue · \(relative)"
    }

    /// Builds every non-empty section, in display order: Overdue, Upcoming,
    /// Done. Within a bucket: overdue and upcoming sort soonest-first
    /// (ascending `remindAt`, matching what "next thing due" means); done
    /// sorts most-recently-completed first (descending `updatedAt`), so
    /// marking one off moves it straight to the top of what it joined.
    ///
    /// `contactNames` is looked up by the caller against the full (uncapped)
    /// set of contacts these reminders belong to — never Home's
    /// `ContactRepository.list` 2000-row cap, which a reminder screen has no
    /// reason to inherit.
    public static func sections(
        reminders: [Reminder],
        contactNames: [String: String],
        nowISO: String
    ) -> [ReminderSection] {
        var buckets: [ReminderBucket: [ReminderRow]] = [:]

        for reminder in reminders where reminder.deletedAt == nil {
            let bucket = classify(reminder, nowISO: nowISO)
            // No live contact, no row — matching RN's `buildReminderListItems`.
            // The contact map is built from `getContactsByIDs`, which filters
            // tombstones, so a missing name means the contact is deleted; a
            // row here would be a nameless entry navigating to a dead screen.
            guard let name = contactNames[reminder.contactID] else { continue }
            let row = ReminderRow(
                reminder: reminder,
                contactName: name,
                metaLine: metaLine(reminder, contactName: name, nowISO: nowISO),
                overdueNote: bucket == .overdue ? overdueNote(reminder, nowISO: nowISO) : nil
            )
            buckets[bucket, default: []].append(row)
        }

        return ReminderBucket.allCases.compactMap { bucket -> ReminderSection? in
            guard let rows = buckets[bucket], !rows.isEmpty else { return nil }
            // The id tie-break mirrors RN's `compareRows`, and matters here
            // for a second reason: `sorted` does not document stability, so
            // without it two rows sharing a timestamp could swap order
            // between reloads.
            let sorted: [ReminderRow]
            switch bucket {
            case .overdue, .upcoming:
                sorted = rows.sorted {
                    ($0.reminder.remindAt, $0.reminder.id) < ($1.reminder.remindAt, $1.reminder.id)
                }
            case .done:
                sorted = rows.sorted {
                    ($0.reminder.updatedAt, $0.reminder.id) > ($1.reminder.updatedAt, $1.reminder.id)
                }
            }
            return ReminderSection(bucket: bucket, rows: sorted)
        }
    }
}
