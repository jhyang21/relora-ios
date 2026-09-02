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

/// The add-reminder form's state and save path. Ports `AddReminderScreen.tsx`
/// — RN has no edit screen for a reminder, only add, so there is no edit mode
/// here either; see the M8b report.
@MainActor
@Observable
public final class AddReminderViewModel {
    public var draft: ReminderDraft
    public private(set) var isSaving = false
    public var errorMessage: String?
    public var showingPriming = false

    @ObservationIgnored public let contactID: String
    @ObservationIgnored public let contactName: String
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let notifications: NotificationEnvironment
    @ObservationIgnored private let userIDProvider: () async -> String
    @ObservationIgnored private let onSaved: () -> Void
    @ObservationIgnored private let coordinator: ReminderNotificationPrimingCoordinator
    @ObservationIgnored private var pendingSave: ValidatedReminderDraft?

    public init(
        contactID: String,
        contactName: String,
        database: AppDatabase,
        notifications: NotificationEnvironment,
        userIDProvider: @escaping () async -> String,
        onSaved: @escaping () -> Void
    ) {
        self.contactID = contactID
        self.contactName = contactName
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
        let reminder = Reminder(
            id: ReloraID.new(),
            contactID: contactID,
            userID: userID,
            title: validated.title,
            remindAt: validated.remindAtISO,
            status: .scheduled,
            createdAt: now,
            updatedAt: now
        )

        let repository = ReminderRepository(database: database)
        // Always nil in practice — every save here mints a fresh id — but
        // looked up for real rather than assumed, so `ReminderScheduling`
        // gets the same shape of input an edit path would give it.
        let existing = try? repository.get(id: reminder.id)
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
