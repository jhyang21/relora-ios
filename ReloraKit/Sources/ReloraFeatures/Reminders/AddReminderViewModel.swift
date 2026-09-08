import Foundation
import Observation
import ReloraCore
import ReloraData
import ReloraServices

/// Whether the notification pre-prompt has already shown once this app run.
///
/// Mirrors the module-level `primedThisSession` flag in RN's
/// `reminderNotificationPriming.ts`. RN's flag lives in a JS module instance
/// that persists for the process and resets on the next launch because a
/// fresh process gets a fresh module; a process-lifetime static is the same
/// shape in Swift. Scoped to this file rather than threaded through
/// `NotificationEnvironment` (ReloraServices, outside this milestone's file
/// ownership) because RN's flag is equally narrow — only
/// `primeReminderNotificationPermission` ever reads or writes it, and that
/// function's only caller is this screen's save action.
@MainActor
enum ReminderPrimingSession {
    static var primedThisSession = false
}

/// The add-reminder form's state and save path. Ports `AddReminderScreen.tsx`.
///
/// RN has only an add screen; 2.5.0 gave this one an edit mode, because a
/// reminder whose time was wrong could not be corrected on either platform
/// (Andrew's 2026-09-07 QA pass). Passing a `reminderID` loads that row and
/// saves back over it; passing nil is the original behaviour, unchanged.
@MainActor
@Observable
public final class AddReminderViewModel {
    public var draft: ReminderDraft
    public private(set) var isSaving = false
    public var errorMessage: String?
    public var showingPriming = false

    @ObservationIgnored public let contactID: String
    @ObservationIgnored public let contactName: String
    /// The row this form edits, or nil when it is creating one.
    @ObservationIgnored public let reminderID: String?
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let notifications: NotificationEnvironment
    @ObservationIgnored private let userIDProvider: () async -> String
    @ObservationIgnored private let onSaved: () -> Void
    @ObservationIgnored private let coordinator: ReminderNotificationPrimingCoordinator
    @ObservationIgnored private var pendingSave: ValidatedReminderDraft?
    @ObservationIgnored private var hasLoaded = false

    public init(
        contactID: String,
        contactName: String,
        reminderID: String? = nil,
        database: AppDatabase,
        notifications: NotificationEnvironment,
        userIDProvider: @escaping () async -> String,
        onSaved: @escaping () -> Void
    ) {
        self.contactID = contactID
        self.contactName = contactName
        self.reminderID = reminderID
        self.database = database
        self.notifications = notifications
        self.userIDProvider = userIDProvider
        self.onSaved = onSaved
        self.draft = ReminderDraft(remindAt: AddReminderForm.defaultRemindAt())
        self.coordinator = ReminderNotificationPrimingCoordinator(
            notifications: notifications,
            settings: AppSettingsStore(database: database)
        )
    }

    /// Whether this form is editing an existing reminder.
    public var isEditing: Bool { reminderID != nil }

    // MARK: Load

    /// Fills the form from the row being edited. A no-op when there is no
    /// `reminderID`, and it runs at most once, so a `.task` that fires twice
    /// cannot throw away what the user has already typed.
    ///
    /// A `remindAt` already in the past is loaded as it stands. The picker's
    /// lower bound is `Date()`, so SwiftUI shows it clamped to now, and
    /// `AddReminderForm.validate` refuses to save until the user genuinely
    /// moves it forward — which is the right outcome for an overdue reminder
    /// someone opened in order to re-arm.
    public func start() async {
        guard let reminderID, !hasLoaded else { return }
        hasLoaded = true

        let database = self.database
        let loaded = await Task.detached(priority: .userInitiated) {
            try? ReminderRepository(database: database).get(id: reminderID)
        }.value
        guard let loaded else { return }

        draft.title = loaded.title
        if let remindAt = ReloraTimestamp.parse(loaded.remindAt) {
            draft.remindAt = remindAt
        }
    }

    // MARK: Save

    public func save() {
        guard !isSaving else { return }
        errorMessage = nil

        let validated: ValidatedReminderDraft
        do {
            validated = try AddReminderForm.validate(title: draft.title, remindAt: draft.remindAt)
        } catch let error as ReminderDraftError {
            errorMessage = error.message
            return
        } catch {
            errorMessage = "Please check the reminder and try again."
            return
        }

        isSaving = true
        Task { await beginSave(validated) }
    }

    /// Settles notification permission before the write lands, so the OS
    /// dialog never appears mid-save — same placement as RN's
    /// `primeReminderNotificationPermission` call in `onSave`. When priming
    /// is due, this suspends the save behind the sheet; `respondToPriming*`
    /// picks it back up once the user answers.
    private func beginSave(_ validated: ValidatedReminderDraft) async {
        if await coordinator.shouldPrime(primedThisSession: ReminderPrimingSession.primedThisSession) {
            ReminderPrimingSession.primedThisSession = true
            pendingSave = validated
            showingPriming = true
            return
        }
        await performSave(validated)
    }

    /// Called by `ReminderNotificationPrimingSheet`'s "Turn on notifications"
    /// button.
    public func respondToPrimingAllow() {
        showingPriming = false
        Task {
            // The user id is resolved before `respondAllow` so a grant can run
            // the repair pass over this user's NULL-id reminders (voice-saved
            // ones, chiefly). `performSave` resolves the same id again; the
            // provider mints at most once, so this is not a second identity.
            await coordinator.respondAllow(userID: await userIDProvider())
            await resumePendingSave()
        }
    }

    /// Called by the sheet's "Not now" button. The priming outcome is never
    /// awaited by the save itself, on either platform — a decline costs the
    /// user nothing but the prompt.
    public func respondToPrimingDecline() {
        showingPriming = false
        coordinator.respondDecline()
        Task { await resumePendingSave() }
    }

    private func resumePendingSave() async {
        guard let validated = pendingSave else {
            isSaving = false
            return
        }
        pendingSave = nil
        await performSave(validated)
    }

    private func performSave(_ validated: ValidatedReminderDraft) async {
        let userID = await userIDProvider()
        let now = ReloraTimestamp.now()

        let repository = ReminderRepository(database: database)
        // The row as it stands before this write: nil for a new reminder, the
        // real row for an edit. Read here rather than reusing what `start()`
        // loaded, so `ReminderScheduling` decides against the row's current
        // state — including a `notification_id` that may have changed since
        // the sheet opened.
        var existing: Reminder?
        if let reminderID {
            existing = try? repository.get(id: reminderID)
        }

        let reminder = Reminder(
            id: existing?.id ?? ReloraID.new(),
            contactID: contactID,
            userID: userID,
            // Carried through so an edit never severs a voice-saved
            // reminder from the memory it came out of.
            memoryID: existing?.memoryID,
            title: validated.title,
            remindAt: validated.remindAtISO,
            // Always `.scheduled`. Saving a future time for a reminder that
            // already fired or was dismissed is someone re-arming it, and a
            // row left `.dismissed` would never notify.
            status: .scheduled,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )

        let notificationsEnabled = (try? AppSettingsStore(database: database).reminderNotificationsEnabled()) ?? true
        let decision = ReminderScheduling.decide(
            existing: existing,
            candidate: reminder,
            notificationsEnabled: notificationsEnabled
        )

        var notificationID: String?
        switch decision {
        case .keep(let id):
            notificationID = id
        case .scheduleNew:
            let remindAtDate = ReloraTimestamp.parse(validated.remindAtISO) ?? Date()
            notificationID = await notifications.scheduler.mint(
                title: reminder.title,
                remindAt: remindAtDate,
                contactID: reminder.contactID
            )
        case .none:
            notificationID = nil
        }

        var toWrite = reminder
        toWrite.notificationID = notificationID

        do {
            try repository.upsert(toWrite)
        } catch {
            // Cleanup-on-write-failure: the OS notification is scheduled,
            // the row is not — cancel it rather than leave a notification
            // with nothing behind it.
            if let notificationID {
                Task { await notifications.scheduler.cancel([notificationID]) }
            }
            errorMessage = "Could not save this reminder. Try again."
            isSaving = false
            return
        }

        if let existingNotificationID = existing?.notificationID, existingNotificationID != notificationID {
            Task { await notifications.scheduler.cancel([existingNotificationID]) }
        }

        isSaving = false
        onSaved()
    }
}
