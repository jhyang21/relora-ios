import Foundation
import ReloraCore

/// What the add-reminder form holds while it is being typed into: strings and
/// a `Date`, exactly as entered, no cleanup applied yet. Ports the local
/// `title`/`remindAt` state in `AddReminderScreen.tsx` — same split
/// `ContactDraft`/`NormalizedContactDraft` uses for contacts.
public struct ReminderDraft: Equatable, Sendable {
    public var title: String
    public var remindAt: Date

    public init(title: String = "", remindAt: Date) {
        self.title = title
        self.remindAt = remindAt
    }
}

/// A draft after validation, in the shape the save path takes.
public struct ValidatedReminderDraft: Equatable, Sendable {
    public var title: String
    public var remindAtISO: String

    public init(title: String, remindAtISO: String) {
        self.title = title
        self.remindAtISO = remindAtISO
    }
}

/// Ports `validateReminderDraft`'s two failure branches. RN's third branch —
/// `remindAt.getTime()` not finite — has no Swift equivalent: a constructed
/// `Date` is always a valid instant, so that check is not ported. See the
/// M8b report.
public enum ReminderDraftError: Error, Equatable, Sendable {
    case missingTitle
    case notInFuture

    /// RN pairs each message with a toast title
    /// (`showError(validation.title, validation.message)`); native shows the
    /// message as an inline error beside the fields it names, where a
    /// second line restating the field would be noise, so only the message
    /// half of the pair is ported.
    public var message: String {
        switch self {
        case .missingTitle: return "Please add a title before saving."
        case .notInFuture: return "Choose a future time so the reminder can be scheduled."
        }
    }
}

public enum AddReminderForm {
    /// Tomorrow at 9:00 AM local time. Ports `getDefaultRemindAt`, which
    /// builds this with `setDate`/`setHours` on a local-time `Date` — the
    /// same local-calendar arithmetic `Calendar.current` does here.
    public static func defaultRemindAt(now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        var components = calendar.dateComponents([.year, .month, .day], from: tomorrow)
        components.hour = 9
        components.minute = 0
        components.second = 0
        return calendar.date(from: components) ?? tomorrow
    }

    /// Whether Save should be enabled. Title is the only field a disabled
    /// button can honestly gate on — future-ness depends on the clock, not
    /// what's been typed, so it stays a save-time check in `validate`
    /// rather than folding into this.
    public static func canSave(title: String) -> Bool {
        !title.trimmed.isEmpty
    }

    /// Trims the title and checks the reminder time is still in the future.
    /// Ports `validateReminderDraft`.
    public static func validate(
        title: String,
        remindAt: Date,
        now: Date = Date()
    ) throws -> ValidatedReminderDraft {
        let trimmed = title.trimmed
        guard !trimmed.isEmpty else {
            throw ReminderDraftError.missingTitle
        }
        guard remindAt > now else {
            throw ReminderDraftError.notInFuture
        }
        return ValidatedReminderDraft(title: trimmed, remindAtISO: ReloraTimestamp.from(remindAt))
    }
}
