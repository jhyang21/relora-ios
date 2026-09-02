import Foundation
import ReloraCore
import ReloraData

/// The onboarding sample example, ported verbatim from `tutorialSeed.ts`. A
/// generic persona — never a real person tied to Relora. Views read these
/// constants; nothing retypes the name, transcript, or reminder title.
public enum TutorialSeed {
    public static let transcript =
        "Coffee with Priya Raman this morning. She just moved into the ops lead role at Northwind, and she's hiring two people this quarter. Her daughter starts college in the fall. I said I'd send her our vendor list next week."

    public static let contactName = "Priya Raman"
    public static let contactPhone = "5555550147"
    public static let contactEmail = "priya.raman@example.com"
    public static let reminderTitle = "Send Priya the vendor list"

    public static let memoryText = "Coffee with Priya. She just moved into the ops lead role at Northwind."
    public static let memoryLabels = ["voice", "tutorial"]

    public static let keyThingRoleText = "Ops lead at Northwind, hiring two people this quarter"
    public static let keyThingFamilyText = "Daughter starts college in the fall"

    /// What `LetsTryItStepView`'s preview card and status copy show while
    /// (or after) the example is created — never persisted, display text
    /// only. Mirrors `buildOnboardingTutorialSuggestions`.
    public struct Preview: Equatable, Sendable {
        public let memoryText: String
        public let keyThingTexts: [String]

        public static let standard = Preview(
            memoryText: TutorialSeed.memoryText,
            keyThingTexts: [TutorialSeed.keyThingRoleText, TutorialSeed.keyThingFamilyText]
        )
    }

    /// Tomorrow at 9:00am, in the device's local calendar — ported from
    /// `buildOnboardingTutorialReminderSuggestion`'s `setDate`/`setHours`,
    /// which run on a bare JS `Date` and so operate in local wall time, not
    /// UTC. `Calendar.current` is the matching native read.
    public static func reminderDate(from now: Date, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        var components = calendar.dateComponents([.year, .month, .day], from: tomorrow)
        components.hour = 9
        components.minute = 0
        components.second = 0
        return calendar.date(from: components) ?? tomorrow
    }
}

/// Creates the tutorial example as one transaction, via the same public
/// composition seam `VoiceCaptureComposerView` uses to land a real voice
/// capture (`VoiceCaptureWrite.save`).
///
/// ## Why not the individual repositories
///
/// `ContactRepository.write`/`MemoryRepository.write`/
/// `KeyThingRepository.write`/`ReminderRepository.write` are all
/// module-internal (`static func write`, no `public`) — ReloraData does not
/// expose them to ReloraFeatures. The only public seam for an atomic
/// multi-table write from outside ReloraData is
/// `VoiceCaptureWrite.save(_:in:)`, which is exactly what a voice capture
/// review screen calls to land its own contact/memory/key-things/reminder —
/// the tutorial seed is functionally a canned voice capture, so it reuses
/// the same seam rather than duplicating a second transaction path.
///
/// ## Why the reminder never gets an OS notification
///
/// RN seeds the tutorial reminder through `upsertReminder(reminder, {
/// disableScheduling: true })` — a write-time flag that skips
/// `expo-notifications` entirely for that one call. `VoiceCaptureWrite.save`
/// has no such flag, and does not need one: it calls
/// `ReminderRepository.write` directly and never touches
/// `NotificationScheduler`, so the reminder this writes is never scheduled
/// by the save itself. The only remaining risk is
/// `NotificationReconciler`'s repair pass, which schedules any
/// `.scheduled` reminder with no `notification_id` — which this reminder
/// is. That reconciler now carries an explicit guard keyed on this
/// reminder's own row id (`AppSettingsKey.onboardingTutorialReminderID`),
/// and `seed` writes that key *before* the transaction, so no moment exists
/// where the reminder row is on disk without its guard — a crash or a
/// concurrent reconciliation pass between the two writes could otherwise
/// schedule a notification for a reminder the user never asked to be
/// notified about. The reverse failure (key written, transaction never
/// commits) leaves the key pointing at a row that does not exist, which
/// guards nothing and harms nothing; the next successful seed overwrites it.
public enum OnboardingTutorialSeedWriter {
    public struct Seeded: Equatable, Sendable {
        public let contactID: String
        public let reminderID: String
    }

    public enum SeedError: Error, Sendable {
        case writeFailed
    }

    @discardableResult
    public static func seed(
        userID: String,
        database: AppDatabase,
        storage: OnboardingStorage,
        now: Date = Date()
    ) throws -> Seeded {
        let nowWire = ReloraTimestamp.now()
        let contactID = ReloraID.new()
        let memoryID = ReloraID.new()
        let reminderID = ReloraID.new()

        let contact = Contact(
            id: contactID,
            userID: userID,
            name: TutorialSeed.contactName,
            phoneNumber: TutorialSeed.contactPhone,
            email: TutorialSeed.contactEmail,
            createdAt: nowWire,
            updatedAt: nowWire
        )

        let memory = Memory(
            id: memoryID,
            contactID: contactID,
            userID: userID,
            text: TutorialSeed.memoryText,
            labels: TutorialSeed.memoryLabels,
            createdAt: nowWire,
            updatedAt: nowWire,
            // Always kept, regardless of the "save voice transcripts"
            // setting — mirrors `persistTranscript: true` in
            // `persistOnboardingTutorialSeed`, a deliberate exception for
            // the one example every install can see.
            transcript: TutorialSeed.transcript,
            source: .voice
        )

        let keyThings = [
            KeyThing(
                id: ReloraID.new(),
                contactID: contactID,
                userID: userID,
                text: TutorialSeed.keyThingRoleText,
                source: .voice,
                createdAt: nowWire,
                updatedAt: nowWire
            ),
            KeyThing(
                id: ReloraID.new(),
                contactID: contactID,
                userID: userID,
                text: TutorialSeed.keyThingFamilyText,
                source: .voice,
                createdAt: nowWire,
                updatedAt: nowWire
            ),
        ]

        let reminder = Reminder(
            id: reminderID,
            contactID: contactID,
            userID: userID,
            memoryID: memoryID,
            title: TutorialSeed.reminderTitle,
            remindAt: ReloraTimestamp.from(TutorialSeed.reminderDate(from: now)),
            status: .scheduled,
            createdAt: nowWire,
            updatedAt: nowWire
            // notificationID left nil — see the type's doc comment.
        )

        // Deliberately not recorded on the usage ledger: `usageEvent` is
        // left nil. RN's own tutorial seed does not report through this
        // path either — `persistVoiceCaptureResult` is called directly,
        // bypassing the review screen's usage-recording call, and
        // `upsertContact` afterward writes only the contact row. Spending
        // one of a guest's five free lifetime notes on an unrecorded demo
        // reads as more likely a latent RN bug than intended behavior; this
        // is flagged as an assumption in the M10 report rather than guessed
        // the other way.
        let plan = VoiceCapturePlan(
            contactID: contactID,
            contact: contact,
            memory: memory,
            keyThings: keyThings,
            reminder: reminder,
            usageEvent: nil
        )

        // Guard first, row second — see the type doc comment. Written before
        // the transaction so the reminder row can never exist, even across a
        // crash, without the reconciler's guard already in place.
        storage.writeTutorialReminderID(reminderID)

        do {
            _ = try VoiceCaptureWrite.save(plan, in: database)
        } catch {
            throw SeedError.writeFailed
        }

        return Seeded(contactID: contactID, reminderID: reminderID)
    }
}
