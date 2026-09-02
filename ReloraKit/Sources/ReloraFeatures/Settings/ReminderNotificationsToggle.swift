import Foundation
import ReloraCore
import ReloraData
import ReloraServices

/// The Settings "Reminder notifications" switch. Ports
/// `enableReminderNotifications` / `disableReminderNotifications`
/// (`reminderNotificationPreferences.ts`) — a deliberate wipe-and-rebuild of
/// every future reminder's OS notification, not
/// `NotificationReconciler.rescheduleAll`'s missing-only repair pass, which
/// only ever touches reminders that currently lack a `notification_id`.
public enum ReminderNotificationsToggle {
    public enum ToggleError: Error, Sendable {
        /// Mirrors RN's `Alert.alert('Notifications permission needed', ...)`
        /// branch in `onToggleReminderNotifications` — the OS refused
        /// permission on enable.
        case permissionDenied
    }

    /// Mirrors `disableReminderNotifications`: cancel every OS notification
    /// this app has pending, then clear `notification_id` on every reminder
    /// that had one.
    ///
    /// Narrower than RN by necessity, not by choice. RN's cancel step
    /// (`cancelAllScheduledNotificationsAsync`) is unscoped — every pending
    /// notification this app has ever scheduled, across any account that has
    /// signed in on the device — and its clear step carries no `user_id`
    /// filter either (`UPDATE reminders SET notification_id = NULL WHERE
    /// notification_id IS NOT NULL`). `ReminderRepository` has no "every
    /// reminder regardless of owner" read, and adding one sits in
    /// ReloraData, outside this milestone's ownership, so both steps here
    /// are scoped to `userID`: only the OS ids this user's own reminders
    /// carry are cancelled, not the device's whole pending queue. A stale
    /// notification left behind by a previously signed-out account on this
    /// device is not touched by this — flagged in the M10 report.
    public static func disable(
        userID: String,
        database: AppDatabase,
        settings: AppSettingsStore,
        notifications: NotificationEnvironment
    ) async throws {
        let repository = ReminderRepository(database: database)
        let rows = try repository.listFullByUser(userID: userID)
        let notificationIDs = rows.compactMap(\.notificationID)
        await notifications.center.removePending(ids: notificationIDs)
        try repository.clearNotificationIDs(notificationIDs)
        try settings.setBoolean(.reminderNotificationsEnabled, false)
    }

    /// Mirrors `enableReminderNotifications`: request permission, then
    /// unconditionally reschedule every `.scheduled`, non-deleted reminder
    /// for `userID` — including ones that already carry a notification id —
    /// writing back a fresh id for each. Throws `.permissionDenied` rather
    /// than proceeding when the OS refuses.
    ///
    /// Carries a tutorial-reminder guard `NotificationReconciler` also
    /// carries, keyed on the row id stored at
    /// `.onboardingTutorialReminderID`. Without it, this wipe-and-rebuild
    /// would scheduled the one reminder the app promises never to notify
    /// for (see `OnboardingTutorialSeedWriter`). RN has no equivalent guard
    /// here — its tutorial reminder is kept off the schedule only by a
    /// write-time `disableScheduling: true` flag on that one save, which an
    /// unconditional rebuild like this one never sees — so a disable/enable
    /// cycle would schedule it in RN. Native closes that hole; see the M10
    /// report.
    ///
    /// Calls `NotificationScheduler.schedule(_:now:)` per reminder rather
    /// than delegating to `NotificationReconciler.rescheduleAll`, because
    /// that reconciler only schedules rows with `notificationID == nil` —
    /// exactly the "missing-only" semantics this toggle must not use.
    /// `schedule(_:now:)` itself carries no such guard (it does not check
    /// `notificationID` at all before minting a new OS request), so any
    /// reminder that still carries an id from before this call is cancelled
    /// and cleared first — otherwise it would end up with two live OS
    /// notifications, the old one orphaned in the OS's pending queue.
    public static func enable(
        userID: String,
        database: AppDatabase,
        settings: AppSettingsStore,
        notifications: NotificationEnvironment,
        now: Date = Date()
    ) async throws {
        let granted = await notifications.center.requestAuthorization()
        guard granted else { throw ToggleError.permissionDenied }

        let tutorialReminderID: String?
        do {
            tutorialReminderID = try settings.getRawValue(.onboardingTutorialReminderID)
        } catch {
            tutorialReminderID = nil
        }

        let repository = ReminderRepository(database: database)
        let rows = try repository.listFullByUser(userID: userID)
        let candidates = Self.candidates(from: rows, excludingTutorialReminderID: tutorialReminderID)

        // Safety pass, mirrored from RN: cancel and clear anything already
        // scheduled among the candidates before rescheduling, so
        // `schedule(_:now:)` — which does not check for an existing id — never
        // mints a second, orphaned OS request alongside one still pending.
        let existingIDs = candidates.compactMap(\.notificationID)
        await notifications.center.removePending(ids: existingIDs)
        try repository.clearNotificationIDs(existingIDs)

        for reminder in candidates {
            var toSchedule = reminder
            toSchedule.notificationID = nil
            await notifications.scheduler.schedule(toSchedule, now: now)
        }

        try settings.setBoolean(.reminderNotificationsEnabled, true)
    }

    /// The pure decision inside `enable`: every `.scheduled`, non-deleted
    /// reminder except the tutorial one, if any. Kept as a standalone
    /// function — rather than inlined into `enable`'s DB/OS-coupled body —
    /// so this filter is testable without a database or notification
    /// center.
    static func candidates(from rows: [Reminder], excludingTutorialReminderID tutorialReminderID: String?) -> [Reminder] {
        rows.filter { reminder in
            guard reminder.status == .scheduled, reminder.deletedAt == nil else { return false }
            if let tutorialReminderID, reminder.id == tutorialReminderID { return false }
            return true
        }
    }
}
