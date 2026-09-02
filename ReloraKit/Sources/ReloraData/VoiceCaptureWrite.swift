import Foundation
import GRDB
import ReloraCore

/// The rows a saved voice capture lands, as one unit.
///
/// A plan, not a decision: which items the user kept, whose contact this is,
/// whether the guest ledger is spent — all of that is settled in
/// `ReloraFeatures.VoiceSaveTransaction` before anything here runs. This type
/// carries the result of those decisions and nothing else, which is what keeps
/// ReloraData free of feature logic while still owning the transaction.
public struct VoiceCapturePlan: Equatable, Sendable {
    /// Who the capture is about. Named on its own rather than read back off
    /// whichever row happens to be present, because the composer navigates to
    /// this contact afterwards and a plan that saved only a reminder still has
    /// somewhere to go.
    public var contactID: String
    /// Written only when the user chose "someone new". An existing contact is
    /// left untouched — RN does the same: `voiceCaptureSave.ts` upserts the
    /// contact only under `createdNewContact`.
    public var contact: Contact?
    /// At most one, matching RN's `if (firstMemoryId) continue;` guard: a
    /// capture writes a single memory however many memory drafts the review
    /// list holds.
    public var memory: Memory?
    public var keyThings: [KeyThing]
    /// Its `memoryID` must name `memory` above, or an existing row — the
    /// reminders table asserts the link.
    public var reminder: Reminder?
    /// Local guests only. Signed-in users' quota is counted from the server
    /// ledger, which `transcribe_audio` writes itself — see
    /// docs/milestone-notes.md, "Usage ledger asymmetry".
    public var usageEvent: UsageEvent?

    public init(
        contactID: String,
        contact: Contact? = nil,
        memory: Memory? = nil,
        keyThings: [KeyThing] = [],
        reminder: Reminder? = nil,
        usageEvent: UsageEvent? = nil
    ) {
        self.contactID = contactID
        self.contact = contact
        self.memory = memory
        self.keyThings = keyThings
        self.reminder = reminder
        self.usageEvent = usageEvent
    }
}

/// What landed. Ports the return value of `persistVoiceCaptureResult`
/// (apps/mobile/src/features/voice/voiceCaptureSave.ts), which the composer
/// uses to decide where to navigate and what the toast says.
public struct VoiceCaptureWriteResult: Equatable, Sendable {
    public var contactID: String
    public var createdNewContact: Bool
    public var memoryCount: Int
    public var keyThingCount: Int
    public var reminderSaved: Bool

    public init(
        contactID: String,
        createdNewContact: Bool,
        memoryCount: Int,
        keyThingCount: Int,
        reminderSaved: Bool
    ) {
        self.contactID = contactID
        self.createdNewContact = createdNewContact
        self.memoryCount = memoryCount
        self.keyThingCount = keyThingCount
        self.reminderSaved = reminderSaved
    }
}

/// Lands a `VoiceCapturePlan` in one transaction.
///
/// Ports the `db.withTransactionAsync` block in `persistVoiceCaptureResult`.
/// All or nothing is the whole point: a memory whose key things failed to
/// write is a worse outcome than a capture the user has to save again, and a
/// guest's spent quota with no note behind it is worse still. Each repository
/// exposes a `Database`-scoped `write` for exactly this — the statements below
/// are the same ones a single-row `upsert` runs, minus their own transactions.
///
/// Order matters twice over: the contact must exist before rows reference it,
/// and the memory must exist before the reminder's `memory_id` link assertion
/// looks for it.
public enum VoiceCaptureWrite {
    public static func save(_ plan: VoiceCapturePlan, in database: AppDatabase) throws -> VoiceCaptureWriteResult {
        try database.write { db in
            try save(plan, db)
        }
    }

    /// The same write against an already-open connection, for a caller that
    /// has its own transaction (tests, and any later flow that wants to fold
    /// a capture into a larger unit).
    public static func save(_ plan: VoiceCapturePlan, _ db: Database) throws -> VoiceCaptureWriteResult {
        if let contact = plan.contact {
            try ContactRepository.write(
                db,
                id: contact.id,
                userID: contact.userID,
                name: contact.name,
                avatarURL: contact.avatarURL,
                descriptors: contact.descriptors,
                phoneNumber: contact.phoneNumber,
                email: contact.email,
                createdAt: contact.createdAt,
                lastInteractionAt: .some(contact.lastInteractionAt),
                deletedAt: contact.deletedAt
            )
        }

        if let memory = plan.memory {
            try MemoryRepository.write(db, memory)
        }

        for item in plan.keyThings {
            try KeyThingRepository.write(db, item)
        }

        if let reminder = plan.reminder {
            try ReminderRepository.write(db, reminder)
        }

        if let event = plan.usageEvent {
            try UsageLedgerRepository.write(
                db,
                id: event.id,
                userID: event.userID,
                processedAt: event.processedAt,
                source: event.source
            )
        }

        return VoiceCaptureWriteResult(
            contactID: plan.contactID,
            createdNewContact: plan.contact != nil,
            memoryCount: plan.memory == nil ? 0 : 1,
            keyThingCount: plan.keyThings.count,
            reminderSaved: plan.reminder != nil
        )
    }
}
