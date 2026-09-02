import Foundation
import ReloraCore
import ReloraData

/// The safety net M6 promised: schedules every reminder that needs an OS
/// notification and does not have one — including a voice-saved reminder,
/// which lands with `notification_id = NULL` on purpose — and cancels every
/// OS-pending notification no live reminder backs. Ports
/// `rescheduleMissingReminderNotifications`.
public struct NotificationReconciler: Sendable {
    /// Why a reconciliation pass is running. Carried for parity with RN's
    /// logging, not branched on — every trigger runs the same pass.
    public enum Trigger: String, Sendable {
        case coldLaunch = "cold-launch"
        case identityApplied = "identity-applied"
        case restore
        case voiceCaptureSaved = "voice-capture-saved"
        /// The priming flow's OS dialog just came back granted. RN runs its
        /// repair pass at this exact moment ("give them their notifications
        /// back rather than waiting for the next sign-in") — reminders kept
        /// while permission was missing hold `notification_id = NULL`.
        case permissionGranted = "permission-granted"
    }

    private let database: AppDatabase
    private let scheduler: NotificationScheduler
    private let center: any NotificationCenterProviding
    private let settings: AppSettingsStore

    public init(
        database: AppDatabase,
        scheduler: NotificationScheduler,
        center: any NotificationCenterProviding,
        settings: AppSettingsStore
    ) {
        self.database = database
        self.scheduler = scheduler
        self.center = center
        self.settings = settings
    }

    public func rescheduleAll(userID: String, trigger: Trigger, now: Date = Date()) async {
        guard (try? settings.reminderNotificationsEnabled()) ?? true else { return }

        // Checks, never requests. A reconciliation pass can run before
        // anyone has seen the priming sheet — cold launch chief among them —
        // and asking the OS here would burn the one system prompt a user
        // ever sees on a moment they did not choose.
        let status = await center.authorizationStatus()
        guard status == .authorized || status == .provisional else { return }

        // Pending BEFORE rows, deliberately. Two passes can overlap (the
        // voice-saved trigger is fire-and-forget), and a pass that read its
        // rows first could see a notification another pass scheduled in
        // between — in `pending` but not in its stale row snapshot — and
        // cancel it, leaving that row holding a dead id nothing repairs.
        // With pending fetched first, an id minted after this snapshot can
        // never appear in it, so a fresh schedule is never "orphaned".
        let pending = await center.pendingIdentifiers()
        guard let rows = try? ReminderRepository(database: database).listFullByUser(userID: userID) else { return }

        // M10: the tutorial reminder is recognized by its own row id, not
        // its title. RN's reconciler carries no guard here at all — the
        // tutorial reminder is kept off the schedule entirely by a
        // write-time `disableScheduling: true` flag on that one save, which
        // this reconciler never sees — so this guard is a native-only
        // strictness addition, not a ported RN mechanism. It also closes a
        // hole RN itself has: RN's own repair pass carries no equivalent
        // guard, so a reminder-notifications disable/enable cycle that
        // clears and later reschedules `notification_id` values would
        // schedule the tutorial reminder in RN. See
        // `OnboardingTutorialSeedWriter` and the M10 report.
        let tutorialReminderID: String?
        do {
            tutorialReminderID = try settings.getRawValue(.onboardingTutorialReminderID)
        } catch {
            tutorialReminderID = nil
        }

        let liveScheduledIDs: Set<String> = Set(rows.compactMap { row in
            guard row.status == .scheduled, row.deletedAt == nil else { return nil }
            return row.notificationID
        })
        let orphaned = pending.filter { !liveScheduledIDs.contains($0) }
        if !orphaned.isEmpty {
            await center.removePending(ids: orphaned)
        }

        for reminder in rows {
            guard reminder.status == .scheduled, reminder.deletedAt == nil else { continue }
            guard reminder.notificationID == nil else { continue }
            if let tutorialReminderID, reminder.id == tutorialReminderID { continue }
            await scheduler.schedule(reminder, now: now)
        }
    }
}

/// The notification stack `AppBootstrap` builds once and hands down —
/// `VoiceCaptureEnvironment`'s counterpart for reminders. Bundled so a
/// composition-root construction and a call site each pass one value instead
/// of three.
public struct NotificationEnvironment: Sendable {
    public let scheduler: NotificationScheduler
    public let reconciler: NotificationReconciler
    public let center: any NotificationCenterProviding
    public let primingStore: ReminderNotificationPrimingStore

    public init(
        scheduler: NotificationScheduler,
        reconciler: NotificationReconciler,
        center: any NotificationCenterProviding,
        primingStore: ReminderNotificationPrimingStore
    ) {
        self.scheduler = scheduler
        self.reconciler = reconciler
        self.center = center
        self.primingStore = primingStore
    }
}
