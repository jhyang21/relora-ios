import Foundation
import ReloraCore

/// What the memory / key-thing edit sheet holds while it is being typed into:
/// the text exactly as entered, and the moment the note records.
///
/// `date` is nil for a key thing, which has no moment of its own. Same split
/// as `ContactDraft`/`NormalizedContactDraft` — nothing is cleaned up until
/// the save path asks for it.
public struct ContactItemDraft: Equatable, Sendable {
    public var text: String
    public var date: Date?

    public init(text: String = "", date: Date? = nil) {
        self.text = text
        self.date = date
    }
}

/// The two rules the edit sheet enforces, kept out of the view so they can be
/// tested without one — the same arrangement as `ContactEditForm`.
public enum ContactItemEditForm {
    /// Whether Save should be enabled.
    ///
    /// Text is required. A date, when there is one, may not be in the future:
    /// a memory records a conversation that already happened, and a note
    /// dated next Tuesday would sort above everything real forever.
    public static func canSave(_ draft: ContactItemDraft, now: Date = Date()) -> Bool {
        guard !draft.text.trimmed.isEmpty else { return false }
        guard let date = draft.date else { return true }
        return date <= now
    }

    /// Trims the text. Save-path text hygiene is a binding ruling in the
    /// milestone notes — the same reason `ContactEditForm.normalize` trims
    /// every field rather than doing it while the user types.
    public static func normalize(_ draft: ContactItemDraft) -> ContactItemDraft {
        ContactItemDraft(text: draft.text.trimmed, date: draft.date)
    }
}
