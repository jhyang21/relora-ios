import Foundation
import ReloraCore

// MARK: - Review items

/// Which section of the review a draft belongs to. Ports
/// `VoiceCaptureReviewItemKind` in
/// apps/mobile/src/features/voice/voiceCaptureReview.ts.
public enum VoiceReviewItemKind: String, Equatable, Sendable {
    case memory
    case keyThing
}

/// One editable line in the review: the extraction's suggestion, the text
/// as the user has since edited it, and whether they are keeping it.
///
/// `Identifiable` on `id` so SwiftUI's `ForEach` tracks a row through an
/// edit. The ids are the extraction's own suggestion ids plus the two
/// synthetic ones below, which is what makes `VoiceSaveIDs` able to hand a
/// retried save the same row id it used the first time.
public struct VoiceReviewItem: Identifiable, Equatable, Sendable {
    /// The memory draft extraction returned. Matches RN's literal id.
    public static let memoryDraftID = "memory-draft"
    /// The memory draft synthesized from the transcript when extraction
    /// returned none. RN's `FALLBACK_TRANSCRIPT_REVIEW_ITEM_ID`.
    public static let fallbackTranscriptID = "fallback-transcript"
    /// Both synthetic memory drafts carry these, and so does the memory row
    /// written from them. RN sets them literally in `voiceCaptureReview.ts`.
    public static let memoryLabels = ["voice", "memory"]

    public var id: String
    public var kind: VoiceReviewItemKind
    public var text: String
    public var labels: [String]
    public var keep: Bool

    public init(id: String, kind: VoiceReviewItemKind, text: String, labels: [String], keep: Bool) {
        self.id = id
        self.kind = kind
        self.text = text
        self.labels = labels
        self.keep = keep
    }
}

/// The review list, split for rendering. RN's `SplitVoiceCaptureReviewItems`.
public struct VoiceReviewSections: Equatable, Sendable {
    public var memories: [VoiceReviewItem] = []
    public var keyThings: [VoiceReviewItem] = []

    public init(memories: [VoiceReviewItem] = [], keyThings: [VoiceReviewItem] = []) {
        self.memories = memories
        self.keyThings = keyThings
    }
}

/// The pure half of the review screen: how extraction output becomes an
/// editable list, and which parts of that list a save would write.
///
/// A line-by-line port of `voiceCaptureReview.ts`. Every rule here is
/// load-bearing on the screen above it, so each is reproduced rather than
/// simplified — see the individual doc comments for the ones that look
/// redundant but are not.
public enum VoiceReview {
    /// Builds the editable list: the polished memory draft (when extraction
    /// produced one with text), then the key things, then — only if nothing
    /// in that list is a memory with text — a memory draft backed by the
    /// transcript.
    public static func buildItems(
        extraction: ExtractionPayload?,
        transcript: String
    ) -> [VoiceReviewItem] {
        var items: [VoiceReviewItem] = []

        if let draft = extraction?.memoryDraft, !draft.text.trimmed.isEmpty {
            items.append(
                VoiceReviewItem(
                    id: VoiceReviewItem.memoryDraftID,
                    kind: .memory,
                    text: draft.text.trimmed,
                    labels: VoiceReviewItem.memoryLabels,
                    keep: true
                )
            )
        }

        for suggestion in extraction?.keyThings ?? [] {
            items.append(
                VoiceReviewItem(
                    id: suggestion.id,
                    kind: .keyThing,
                    text: suggestion.text,
                    labels: suggestion.labels,
                    keep: true
                )
            )
        }

        return ensuringMemoryDraft(items, transcript: transcript)
    }

    /// Guarantees the list offers one memory to edit.
    ///
    /// With a transcript the draft starts from it. With none — a silent
    /// recording, or a guest whose transcription came back `AUTH_REQUIRED`
    /// — the draft starts empty and the user types the note themselves.
    ///
    /// Note what the test is **not**: it does not consider `keep`. RN's
    /// `ensureVoiceCaptureMemoryReviewItems` checks kind and text only, so
    /// a user who switches the one memory off does not get a second one
    /// appended underneath it.
    public static func ensuringMemoryDraft(
        _ items: [VoiceReviewItem],
        transcript: String
    ) -> [VoiceReviewItem] {
        let hasMemory = items.contains { $0.kind == .memory && !$0.text.trimmed.isEmpty }
        guard !hasMemory else { return items }

        return items + [
            VoiceReviewItem(
                id: VoiceReviewItem.fallbackTranscriptID,
                kind: .memory,
                text: transcript.trimmed,
                labels: VoiceReviewItem.memoryLabels,
                keep: true
            )
        ]
    }

    /// Only what the user kept, and only where they left text behind.
    public static func acceptedItems(_ items: [VoiceReviewItem]) -> [VoiceReviewItem] {
        items.filter { $0.keep && !$0.text.trimmed.isEmpty }
    }

    public static func sections(_ items: [VoiceReviewItem]) -> VoiceReviewSections {
        var sections = VoiceReviewSections()
        for item in items {
            if item.kind == .memory {
                sections.memories.append(item)
            } else {
                sections.keyThings.append(item)
            }
        }
        return sections
    }

    /// A suggested reminder starts accepted. RN's
    /// `getInitialReminderSelection` — the suggestion only exists because
    /// the user said something that sounded like a commitment, so the
    /// default is to keep it and the toggle is there to say otherwise.
    public static func initialReminderSelection(
        _ suggestion: ExtractionReminderSuggestion?
    ) -> Bool {
        suggestion != nil
    }

    // MARK: Transitions

    /// Replaces one item's text. Editing never trims — trimming while
    /// someone is typing eats the space before their next word. The save
    /// path trims instead (docs/milestone-notes.md, "Save-path text
    /// hygiene"), which is also where `ContactEditView` does it.
    public static func settingText(
        _ items: [VoiceReviewItem],
        id: String,
        text: String
    ) -> [VoiceReviewItem] {
        items.map { item in
            guard item.id == id else { return item }
            var updated = item
            updated.text = text
            return updated
        }
    }

    public static func togglingKeep(_ items: [VoiceReviewItem], id: String) -> [VoiceReviewItem] {
        items.map { item in
            guard item.id == id else { return item }
            var updated = item
            updated.keep.toggle()
            return updated
        }
    }
}

// MARK: - Contact resolution

/// Who the capture is about. RN's `VoiceCaptureReviewSelection`.
public enum VoiceContactSelection: Equatable, Sendable {
    case existing(contactID: String, contactName: String)
    case new(name: String)

    /// The name to show on the review screen for this selection.
    public var displayName: String {
        switch self {
        case .existing(_, let name): return name
        case .new(let name): return name
        }
    }
}

/// What the picker offers, in the order it offers it.
///
/// A chip per candidate plus a "someone new" chip. `MatchCandidate.reason`
/// is user-facing copy the matcher already wrote ("Strong subject-name
/// match, supported by transcript"), so it is shown rather than restated.
public struct VoiceContactChip: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case existing(contactID: String)
        case new
    }

    public var kind: Kind
    public var name: String
    /// Nil for the "someone new" chip, which needs no justification.
    public var reason: String?

    public var id: String {
        switch kind {
        case .existing(let contactID): return contactID
        case .new: return "new"
        }
    }

    public init(kind: Kind, name: String, reason: String?) {
        self.kind = kind
        self.name = name
        self.reason = reason
    }
}

/// Turning matcher output into a preselection and a row of chips.
public enum VoiceContactResolution {
    /// The chips for a match result, newest-name field included.
    ///
    /// The "someone new" chip is always last and always present: the
    /// matcher's job is to guess, and a guess the user cannot decline is
    /// not a guess. `newContactName` is what the chip is labelled with once
    /// it has a name to show.
    public static func chips(
        for result: MatchResult,
        newContactName: String
    ) -> [VoiceContactChip] {
        var chips = result.candidates.map { candidate in
            VoiceContactChip(
                kind: .existing(contactID: candidate.contactID),
                name: candidate.name,
                reason: candidate.reason
            )
        }
        let trimmedName = newContactName.trimmed
        chips.append(
            VoiceContactChip(
                kind: .new,
                name: trimmedName.isEmpty ? "Someone new" : trimmedName,
                reason: nil
            )
        )
        return chips
    }

    /// Which chip starts selected.
    ///
    /// Ports `buildProcessedCaptureState` in `VoiceCaptureComposerScreen.tsx`,
    /// in its order: a composer opened from a contact is about that contact,
    /// whatever the transcript says; otherwise a confident match is taken;
    /// otherwise nothing is chosen and the picker opens.
    public static func initialSelection(
        result: MatchResult,
        initialContactID: String?
    ) -> VoiceContactChip.Kind? {
        if let initialContactID, !initialContactID.isEmpty {
            return .existing(contactID: initialContactID)
        }
        guard result.status == .matched else { return nil }

        switch result.defaultSelection {
        case .contactID(let contactID): return .existing(contactID: contactID)
        case .new: return .new
        case .notSet: return nil
        }
    }

    /// The name a new contact would be created under: the transcript's
    /// subject guess, else the contact the composer was opened from, else
    /// nothing. Ports `getInitialNewContactName`
    /// (`voiceCaptureContactState.ts`).
    public static func initialNewContactName(
        subjectNameGuess: String?,
        initialContactName: String?
    ) -> String {
        let guess = (subjectNameGuess ?? "").trimmed
        if !guess.isEmpty { return guess }
        return (initialContactName ?? "").trimmed
    }

    /// Whether the picker's confirm button may act. Ports
    /// `canConfirmVoiceCaptureContact`.
    public static func canConfirm(
        selection: VoiceContactChip.Kind?,
        newContactName: String
    ) -> Bool {
        switch selection {
        case .existing: return true
        case .new: return !newContactName.trimmed.isEmpty
        case nil: return false
        }
    }

    /// The selection a save would use, or nil while the choice is still
    /// incomplete. A `.new` chip with no name typed is not yet a selection.
    public static func resolve(
        selection: VoiceContactChip.Kind?,
        newContactName: String,
        nameForContactID: (String) -> String?
    ) -> VoiceContactSelection? {
        switch selection {
        case .existing(let contactID):
            guard let name = nameForContactID(contactID) else { return nil }
            return .existing(contactID: contactID, contactName: name)
        case .new:
            let name = newContactName.trimmed
            return name.isEmpty ? nil : .new(name: name)
        case nil:
            return nil
        }
    }
}
