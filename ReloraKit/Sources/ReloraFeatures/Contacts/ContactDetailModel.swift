import Foundation
import ReloraCore
import ReloraData

/// The three things a contact holds.
///
/// Ports `ContactDetailTab` (apps/mobile/src/features/contacts/contactDetailPresentation.ts).
public enum ContactDetailTab: String, CaseIterable, Identifiable, Equatable, Sendable {
    case memories
    case keyThings
    case reminders

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .memories: return "Memories"
        case .keyThings: return "Key Things"
        case .reminders: return "Reminders"
        }
    }

    /// The matching store kind, for the delete/restore calls.
    public var itemKind: ContactItemKind {
        switch self {
        case .memories: return .memory
        case .keyThings: return .keyThing
        case .reminders: return .reminder
        }
    }
}

public enum ContactDetailModel {

    // MARK: Sorting

    /// Newest first by when it happened. Ties fall back to `updatedAt` and then
    /// `id`, so the order is total — a list that reshuffles between two renders
    /// because two rows compared equal is worse than a slightly arbitrary order.
    public static func sortedMemories(_ items: [Memory]) -> [Memory] {
        items
            .filter { $0.deletedAt == nil }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
    }

    /// Newest first by when it was last touched. Key things are facts that get
    /// corrected, so "recently edited" beats "recently created" here.
    public static func sortedKeyThings(_ items: [KeyThing]) -> [KeyThing] {
        items
            .filter { $0.deletedAt == nil }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id < rhs.id
            }
    }

    /// Soonest first. Reminders are about what is coming.
    public static func sortedReminders(_ items: [Reminder]) -> [Reminder] {
        items
            .filter { $0.deletedAt == nil }
            .sorted { lhs, rhs in
                if lhs.remindAt != rhs.remindAt { return lhs.remindAt < rhs.remindAt }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id < rhs.id
            }
    }

    // MARK: Row copy

    /// "tomorrow", "yesterday · overdue", "Aug 3 at 4:25 PM · dismissed".
    ///
    /// Ports `formatContactDetailReminderMeta`. A terminal status is named
    /// because "fired" and "dismissed" are different histories; a scheduled
    /// reminder whose time has passed says so, because that is the one a user
    /// needs to do something about.
    public static func reminderMeta(_ reminder: Reminder, nowISO: String) -> String {
        let when = ReloraRelativeTime.friendlyDateTime(reminder.remindAt, now: nowISO)

        guard reminder.status == .scheduled else {
            return "\(when) · \(reminder.status.rawValue)"
        }

        guard let remindAt = ReloraTimestamp.parse(reminder.remindAt),
              let now = ReloraTimestamp.parse(nowISO) else {
            return when
        }
        return remindAt <= now ? "\(when) · overdue" : when
    }

    // MARK: Delete wording

    /// The four strings an item delete needs.
    ///
    /// Ports `buildContactItemDeleteCopy`. An item delete has **no confirmation
    /// dialog** — it happens, and the toast carries Undo for a few seconds. That
    /// is the product's stance on destructive actions and the reason the toast
    /// layer exists at all.
    public struct ItemDeleteCopy: Equatable, Sendable {
        public var deleteLabel: String
        public var deletedMessage: String
        public var restoredMessage: String
        public var deleteFailedMessage: String
        public var undoFailedMessage: String
    }

    public static func itemDeleteCopy(_ kind: ContactItemKind) -> ItemDeleteCopy {
        let noun: String
        switch kind {
        case .memory: noun = "Memory"
        case .keyThing: noun = "Key thing"
        case .reminder: noun = "Reminder"
        }
        let lower = noun.lowercased()

        return ItemDeleteCopy(
            deleteLabel: "Delete \(lower)",
            deletedMessage: "\(noun) deleted",
            restoredMessage: "\(noun) restored",
            deleteFailedMessage: "Could not delete this \(lower).",
            undoFailedMessage: "Could not restore this \(lower)."
        )
    }

    // MARK: Contact delete

    /// Whether deleting this contact needs a confirmation first.
    ///
    /// Ports `needsContactDeleteConfirmation`. **Memories or key things, not
    /// reminders.** A contact carrying only reminders loses nothing a person
    /// wrote, so it deletes like any other row and relies on Undo. A contact
    /// carrying notes is the one case in the product where the alert-vs-toast
    /// rule says confirm first: the delete cascades over content the user
    /// authored, and Undo is a few seconds against work that took months.
    public static func needsDeleteConfirmation(_ counts: ContactRepository.ContentCounts) -> Bool {
        counts.memories > 0 || counts.keyThings > 0
    }

    /// "2 memories, a key thing, and 3 reminders". Ports `summarizeContactContent`.
    public static func summarizeContent(_ counts: ContactRepository.ContentCounts) -> String {
        var parts: [String] = []
        if counts.memories > 0 {
            parts.append(counts.memories == 1 ? "a memory" : "\(counts.memories) memories")
        }
        if counts.keyThings > 0 {
            parts.append(counts.keyThings == 1 ? "a key thing" : "\(counts.keyThings) key things")
        }
        if counts.reminders > 0 {
            parts.append(counts.reminders == 1 ? "a reminder" : "\(counts.reminders) reminders")
        }

        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default:
            let last = parts.removeLast()
            return "\(parts.joined(separator: ", ")), and \(last)"
        }
    }

    public struct DeleteConfirmation: Equatable, Sendable {
        public var title: String
        public var message: String
        public var confirmLabel: String
    }

    public static func deleteConfirmation(
        name: String,
        counts: ContactRepository.ContentCounts
    ) -> DeleteConfirmation {
        DeleteConfirmation(
            title: "Delete \(name)?",
            message: """
                This also deletes \(summarizeContent(counts)) saved for \(name), \
                on this device and everywhere else you use Relora. You get a few \
                seconds to undo.
                """,
            confirmLabel: "Delete contact"
        )
    }

    /// What to assume when the content count cannot be read.
    ///
    /// Ports the fallback in `contactDeleteActions.ts`: one memory, so the
    /// caller confirms rather than deleting silently. A failed read must never
    /// be the reason a contact's notes vanish without a question.
    public static let unknownContentCounts = ContactRepository.ContentCounts(
        memories: 1,
        keyThings: 0,
        reminders: 0
    )
}
