import Foundation
import ReloraCore

/// What the context card says about one person.
///
/// Ports `ContextCardContent` (apps/mobile/src/features/home/highlights.ts).
/// The contact id travels with the content on purpose — see
/// `HomeViewModel.contextCard`. The one thing this card must never do is put one
/// person's notes under another person's name, and the way that happens is
/// content arriving from a load that started before the selected contact
/// changed.
public struct ContextCardContent: Equatable, Sendable {
    public var contactID: String
    public var highlights: [String]
    public var memorySnippet: String?
    public var nextReminder: String?
}

public enum ContextCardModel {
    /// Home is a glance before a conversation, so it shows fewer lines.
    public static let homeHighlightLimit = 3

    /// The most useful things to know, in the order a person would want them.
    ///
    /// Ports `buildContextHighlights`. Manual key things outrank extracted ones —
    /// something a user typed themselves is something they decided mattered —
    /// and within each group the most recently touched comes first.
    static func highlights(
        keyThings: [KeyThing],
        memories: [Memory],
        reminders: [Reminder],
        nowISO: String
    ) -> (highlights: [String], memorySnippet: String?, nextReminder: String?) {
        let ranked = keyThings
            .filter { $0.deletedAt == nil }
            .sorted { lhs, rhs in
                let lhsManual = lhs.source == .manual
                let rhsManual = rhs.source == .manual
                if lhsManual != rhsManual {
                    return lhsManual
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(6)
            .map(\.text)

        let memorySnippet = memories
            .filter { $0.deletedAt == nil }
            .max { $0.createdAt < $1.createdAt }
            .map { String($0.text.prefix(100)) }

        let nowMS = ReloraTimestamp.parse(nowISO)?.timeIntervalSince1970

        let nextReminder = reminders
            .filter { reminder in
                guard reminder.status == .scheduled, reminder.deletedAt == nil else { return false }
                guard let nowMS,
                      let remindAt = ReloraTimestamp.parse(reminder.remindAt)?.timeIntervalSince1970 else {
                    return false
                }
                return remindAt > nowMS
            }
            .min { $0.remindAt < $1.remindAt }
            .map(\.title)

        return (Array(ranked), memorySnippet, nextReminder)
    }

    /// The card, or nothing.
    ///
    /// Ports `buildContextCard`. The emptiness test runs on what would render,
    /// not on the raw rows: a contact whose only memory is deleted, or whose only
    /// reminder has already passed, still arrives here with non-empty arrays and
    /// nothing to show, and an empty card under a person's name teaches the
    /// reader nothing.
    public static func build(
        contactID: String,
        keyThings: [KeyThing],
        memories: [Memory],
        reminders: [Reminder],
        limit: Int,
        nowISO: String
    ) -> ContextCardContent? {
        let derived = highlights(
            keyThings: keyThings,
            memories: memories,
            reminders: reminders,
            nowISO: nowISO
        )
        let limited = Array(derived.highlights.prefix(limit))

        if limited.isEmpty, derived.memorySnippet == nil, derived.nextReminder == nil {
            return nil
        }

        return ContextCardContent(
            contactID: contactID,
            highlights: limited,
            memorySnippet: derived.memorySnippet,
            nextReminder: derived.nextReminder
        )
    }
}
