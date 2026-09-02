import Foundation
import ReloraCore
import ReloraData

// MARK: - Stable ids

/// The row ids one capture will use, minted once and reused.
///
/// Ports `voiceCaptureSaveSession.ts`. The point is retries: every write in
/// `VoiceCaptureWrite` is an upsert keyed on id, so a save that fails halfway
/// and is tried again lands the same rows a second time instead of a duplicate
/// set. Fresh ids on each attempt would turn one interrupted save into two
/// memories about the same conversation — and, for a guest, two spent notes.
///
/// A value type with mutating accessors rather than a cache behind a lock: the
/// composer owns exactly one of these, on the main actor, for the life of one
/// capture.
public struct VoiceSaveIDs: Equatable, Sendable {
    private var storedContactID: String?
    private var storedReminderID: String?
    private var storedUsageEventID: String?
    private var storedRowIDs: [String: String] = [:]

    public init() {}

    /// The id a newly created contact gets.
    public mutating func newContactID() -> String {
        if let storedContactID { return storedContactID }
        let id = ReloraID.new()
        storedContactID = id
        return id
    }

    public mutating func reminderID() -> String {
        if let storedReminderID { return storedReminderID }
        let id = ReloraID.new()
        storedReminderID = id
        return id
    }

    /// Stable across retries so `INSERT OR IGNORE` can do its job: a guest's
    /// quota is spent once however many times the save is attempted.
    public mutating func usageEventID() -> String {
        if let storedUsageEventID { return storedUsageEventID }
        let id = ReloraID.new()
        storedUsageEventID = id
        return id
    }

    /// The row id for a review item, keyed by the item's own id.
    ///
    /// Review-item ids come from extraction (`memory-draft`, the key-thing
    /// suggestion ids) and are stable within a capture but meaningless as
    /// database keys, so each maps to one minted row id.
    public mutating func rowID(for reviewItemID: String) -> String {
        if let existing = storedRowIDs[reviewItemID] { return existing }
        let id = ReloraID.new()
        storedRowIDs[reviewItemID] = id
        return id
    }
}

// MARK: - Input

/// Everything a save needs, once the user has stopped deciding.
public struct VoiceSaveInput: Equatable, Sendable {
    public var userID: String
    public var selection: VoiceContactSelection
    /// The full review list. Filtering to what was kept happens here, not at
    /// the call site, so the rule lives in one place.
    public var items: [VoiceReviewItem]
    public var transcript: String
    /// `saveVoiceTranscripts` is on **and** the transcript came from the
    /// server. A guest's self-written note has no transcript to keep — see
    /// `usedLocalGuestFallback` in `VoiceCaptureComposerScreen.tsx`.
    public var persistTranscript: Bool
    public var reminderSuggestion: ExtractionReminderSuggestion?
    public var acceptReminder: Bool
    /// When the user moved the suggested date. Nil keeps the suggestion's own
    /// `remind_at` — see the deviation note on `reminder(...)` below.
    public var reminderRemindAt: String?
    /// The recording on disk, kept for replay. Nil once the user has
    /// discarded it or the file could not be written.
    public var audioLocalURI: String?
    /// Local guests only. A signed-in user's note was counted by
    /// `transcribe_audio` on the server before it ever came back.
    public var recordsUsageEvent: Bool

    public init(
        userID: String,
        selection: VoiceContactSelection,
        items: [VoiceReviewItem],
        transcript: String,
        persistTranscript: Bool,
        reminderSuggestion: ExtractionReminderSuggestion? = nil,
        acceptReminder: Bool = false,
        reminderRemindAt: String? = nil,
        audioLocalURI: String? = nil,
        recordsUsageEvent: Bool
    ) {
        self.userID = userID
        self.selection = selection
        self.items = items
        self.transcript = transcript
        self.persistTranscript = persistTranscript
        self.reminderSuggestion = reminderSuggestion
        self.acceptReminder = acceptReminder
        self.reminderRemindAt = reminderRemindAt
        self.audioLocalURI = audioLocalURI
        self.recordsUsageEvent = recordsUsageEvent
    }
}

/// Why a save could not be built.
///
/// One case, not RN's three. `CONTACT_REQUIRED` and `TRANSCRIPT_REQUIRED` are
/// both gone, for different reasons:
///
/// - **Contact:** `VoiceSaveInput.selection` is a non-optional
///   `VoiceContactSelection`, so "no contact chosen" cannot be expressed. The
///   composer's Save button stays disabled until `VoiceContactResolution.resolve`
///   returns one, which is the same guard moved into the type system.
/// - **Transcript:** RN rejects an empty transcript outright, which in this
///   port would reject the *common* guest path — a local guest has no session,
///   so transcription always returns `AUTH_REQUIRED` and the user writes the
///   note by hand against an empty transcript. See the M6 report; the
///   consequence is handled in `plan(...)`, which skips the transcript-backed
///   memory rather than writing an empty row.
public enum VoiceSaveError: Error, Equatable, Sendable {
    /// Nothing was kept and no reminder was accepted. RN's `NO_REVIEW_ITEMS`.
    case noReviewItems
}

// MARK: - Building and running the save

/// Turns a finished review into rows, then lands them.
///
/// Ports `persistVoiceCaptureResult` (`voiceCaptureSave.ts`) split in two: this
/// type decides *what* to write, `ReloraData.VoiceCaptureWrite` decides *how* to
/// write it atomically. The split is what keeps feature rules — which memory
/// wins, whose ledger is charged, what gets trimmed — out of ReloraData, which
/// cannot import them and should not know them.
public enum VoiceSaveTransaction {

    /// Builds the rows. Pure: the same input and ids give the same plan, which
    /// is what makes the save rules testable without a database.
    ///
    /// Trimming happens here and only here. Editing a review item never trims
    /// (trimming mid-typing eats the space before the next word), so every
    /// text field is trimmed on the way to a row —  including the reminder
    /// title, which RN leaves untrimmed. See docs/milestone-notes.md,
    /// "Save-path text hygiene".
    public static func plan(
        _ input: VoiceSaveInput,
        ids: inout VoiceSaveIDs,
        now: Date = Date()
    ) throws -> VoiceCapturePlan {
        let nowISO = ReloraTimestamp.from(now)
        let transcript = input.transcript.trimmed

        var accepted = VoiceReview.acceptedItems(input.items)
        // RN re-runs the ensure at save time so a user who switched the one
        // memory off still gets the transcript saved as a note. With no
        // transcript there is nothing to make a note out of, and appending
        // here would write a memory row with empty text — the case RN's
        // `TRANSCRIPT_REQUIRED` throw stops before it can happen.
        if !transcript.isEmpty {
            accepted = VoiceReview.ensuringMemoryDraft(accepted, transcript: transcript)
        }

        let savesReminder = input.acceptReminder && input.reminderSuggestion != nil
        guard !accepted.isEmpty || savesReminder else {
            throw VoiceSaveError.noReviewItems
        }

        let contactID: String
        var newContact: Contact?
        switch input.selection {
        case .existing(let existingID, _):
            contactID = existingID
        case .new(let name):
            let id = ids.newContactID()
            contactID = id
            newContact = Contact(
                id: id,
                userID: input.userID,
                name: name.trimmed,
                avatarURL: nil,
                descriptors: [],
                phoneNumber: nil,
                email: nil,
                createdAt: nowISO,
                updatedAt: nowISO,
                lastInteractionAt: nil,
                deletedAt: nil
            )
        }

        var memory: Memory?
        var keyThings: [KeyThing] = []

        for item in accepted {
            switch item.kind {
            case .memory:
                // One memory per capture, however many memory drafts the list
                // holds. RN's `if (firstMemoryId) continue;` — a capture is
                // one thing that happened, so it is one timeline entry.
                guard memory == nil else { continue }
                memory = Memory(
                    id: ids.rowID(for: item.id),
                    contactID: contactID,
                    userID: input.userID,
                    text: item.text.trimmed,
                    labels: item.labels,
                    createdAt: nowISO,
                    updatedAt: nowISO,
                    audioURL: nil,
                    audioLocalURI: input.audioLocalURI,
                    transcript: input.persistTranscript ? transcript : nil,
                    source: .voice,
                    deletedAt: nil
                )

            case .keyThing:
                keyThings.append(
                    KeyThing(
                        id: ids.rowID(for: item.id),
                        contactID: contactID,
                        userID: input.userID,
                        text: item.text.trimmed,
                        source: .voice,
                        createdAt: nowISO,
                        updatedAt: nowISO,
                        deletedAt: nil
                    )
                )
            }
        }

        var reminder: Reminder?
        if savesReminder, let suggestion = input.reminderSuggestion {
            reminder = Reminder(
                id: ids.reminderID(),
                contactID: contactID,
                userID: input.userID,
                // Links to the memory when there is one. `nil` is not a
                // failure: a capture can be a reminder and nothing else.
                memoryID: memory?.id,
                title: suggestion.title.trimmed,
                remindAt: input.reminderRemindAt ?? suggestion.remindAt,
                status: .scheduled,
                createdAt: nowISO,
                updatedAt: nowISO,
                // M8 owns scheduling. The row is written now and the
                // notification is attached later, which is also what makes a
                // reminder survive a denied notification permission.
                notificationID: nil,
                deletedAt: nil
            )
        }

        var usageEvent: UsageEvent?
        if input.recordsUsageEvent {
            usageEvent = UsageEvent(
                id: ids.usageEventID(),
                userID: input.userID,
                processedAt: nowISO,
                source: QuotaPolicy.clientUsageEventSource,
                serverSyncedAt: nil
            )
        }

        return VoiceCapturePlan(
            contactID: contactID,
            contact: newContact,
            memory: memory,
            keyThings: keyThings,
            reminder: reminder,
            usageEvent: usageEvent
        )
    }

    /// Writes a built plan, off the main actor.
    ///
    /// Deliberately separate from `plan(...)` rather than one `save` that does
    /// both. `ids` lives on the composer, which is `@MainActor`, and Swift 6
    /// refuses to pass actor-isolated state `inout` across an `async` call —
    /// so the plan is built synchronously where the ids live, and only the
    /// finished plan (which is `Sendable`) crosses over.
    ///
    /// A guest's usage event rides inside this transaction rather than
    /// following it as RN's `recordVoiceNoteProcessed()` does: a note that
    /// failed to save must not leave a spent quota behind it.
    public static func execute(
        _ plan: VoiceCapturePlan,
        database: AppDatabase
    ) async throws -> VoiceCaptureWriteResult {
        try await Task.detached(priority: .userInitiated) {
            try VoiceCaptureWrite.save(plan, in: database)
        }.value
    }
}
