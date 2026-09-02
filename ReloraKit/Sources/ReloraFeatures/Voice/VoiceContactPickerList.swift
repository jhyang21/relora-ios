import Foundation
import ReloraCore

/// The contact list the picker sheet offers.
///
/// Ports `buildVoiceContactPickerOptions` (`voiceContactPickerList.ts`). Its
/// `VoiceContactPickerOption` type is not ported alongside it — it carries the
/// same three fields as `VoiceContactChip` (`contactId`, `name`, `reason`), and
/// one type the sheet can render everywhere beats two that differ only by
/// filename.
public enum VoiceContactPickerList {
    /// Enough of the address book to pick from without turning the sheet into
    /// a directory. RN's `VOICE_CONTACT_PICKER_LIST_LIMIT`.
    public static let limit = 24

    /// With a search query the whole address book is searched. Without one the
    /// scored candidates come first, then everyone else.
    ///
    /// That second rule is a fix RN already made and this port inherits: the
    /// sheet once rendered scored candidates alone, so a note that matched
    /// nobody offered no way to reach a contact that already existed.
    public static func options(
        candidates: [MatchCandidate],
        contacts: [Contact],
        query: String,
        limit: Int = limit
    ) -> [VoiceContactChip] {
        let normalizedQuery = query.trimmed.lowercased()
        // A contact with a blank name is unpickable — there is nothing to
        // show on the row and nothing to search against.
        let named = contacts.filter { !$0.name.trimmed.isEmpty }

        if !normalizedQuery.isEmpty {
            return named
                .filter { $0.name.lowercased().contains(normalizedQuery) }
                .prefix(limit)
                .map(chip(for:))
        }

        let candidateIDs = Set(candidates.map(\.contactID))
        let scored = candidates.map { candidate in
            VoiceContactChip(
                kind: .existing(contactID: candidate.contactID),
                name: candidate.name,
                reason: candidate.reason
            )
        }
        let rest = named
            .filter { !candidateIDs.contains($0.id) }
            .map(chip(for:))

        return Array((scored + rest).prefix(limit))
    }

    /// A plain list entry: offered because it exists, not because the
    /// transcript pointed at it, so it carries no reason to show.
    private static func chip(for contact: Contact) -> VoiceContactChip {
        VoiceContactChip(
            kind: .existing(contactID: contact.id),
            name: contact.name,
            reason: nil
        )
    }
}
