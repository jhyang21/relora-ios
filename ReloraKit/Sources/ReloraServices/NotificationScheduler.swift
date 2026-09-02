import Foundation
import ReloraCore
import ReloraData

/// Schedules and cancels one reminder's OS notification, and writes the id
/// it got back onto the row.
///
/// ## Minting the notification id — a deviation from RN
///
/// `expo-notifications`' `scheduleNotificationAsync` mints an id and hands it
/// back. `UNUserNotificationCenter.add(_:)` takes the opposite shape: the
/// caller supplies the identifier up front. `ReloraID.new()` stands in for
/// Expo's generator here — flagged in the M8 report as a first-build check,
/// since nothing on this Windows machine has run `UNNotificationRequest`
/// against a real center to confirm the identifier format has no hidden
/// constraint.
public struct NotificationScheduler: Sendable {
    private let center: any NotificationCenterProviding
    private let database: AppDatabase

    public init(center: any NotificationCenterProviding, database: AppDatabase) {
        self.center = center
        self.database = database
    }

    /// Ported verbatim from the RN notification content.
    static let bodyText = "Tap to open this contact and check it off."

    /// Schedules `reminder` if it is `.scheduled`, not tombstoned, and due
    /// in the future.
    ///
    /// Deliberately does NOT check `notificationID` — callers own that
    /// decision. `NotificationReconciler` schedules only nil-id rows by its
    /// own filter, while `ReminderNotificationsToggle.enable`'s
    /// wipe-and-rebuild cancels and clears existing ids first precisely
    /// because this function would otherwise mint a second OS request
    /// alongside a live one.
    ///
    /// A past-due reminder is not scheduled. `UNCalendarNotificationTrigger`
    /// built from a date already behind `now` never fires — asking the OS to
    /// file a request that can never deliver is worse than skipping it, and
    /// `NotificationReconciler` re-checks every pass, so nothing is lost by
    /// waiting for whoever edits the reminder to move it into the future.
    @discardableResult
    public func schedule(_ reminder: Reminder, now: Date = Date()) async -> Bool {
        guard reminder.status == .scheduled, reminder.deletedAt == nil else { return false }
        guard let remindAt = ReloraTimestamp.parse(reminder.remindAt), remindAt > now else { return false }

        let notificationID = ReloraID.new()
        do {
            try await center.schedule(
                id: notificationID,
                title: reminder.title,
                body: Self.bodyText,
                date: remindAt,
                userInfo: ["url": "relora://contact/\(reminder.contactID)"]
            )
        } catch {
            return false
        }

        try? ReminderRepository(database: database).setNotificationID(reminder.id, notificationID: notificationID)
        return true
    }

    /// Mints and schedules a notification from a title/date/contact directly,
    /// without touching the reminders table. `schedule(_:now:)` above assumes
    /// the row already exists — it looks up nothing and writes
    /// `notification_id` back onto the row by id — which does not hold for a
    /// reminder that has not been written yet.
    ///
    /// `AddReminderViewModel` (ReloraFeatures) needs the OS id *before* its
    /// own write, mirroring RN's `upsertReminder`: schedule first, so a write
    /// failure has an id to roll back by cancelling. Added for M8b; a file
    /// outside that milestone's strict ownership, same as M8's
    /// `RestorableReminder` init — flagged in the M8b report.
    @discardableResult
    public func mint(title: String, remindAt: Date, contactID: String) async -> String? {
        let notificationID = ReloraID.new()
        do {
            try await center.schedule(
                id: notificationID,
                title: title,
                body: Self.bodyText,
                date: remindAt,
                userInfo: ["url": "relora://contact/\(contactID)"]
            )
            return notificationID
        } catch {
            return nil
        }
    }

    /// Cancels OS notifications by id. Step 1 of the two-step ordering in
    /// `docs/milestone-notes.md` — every caller clears `notification_id`
    /// locally only after this returns.
    public func cancel(_ notificationIDs: [String]) async {
        await center.removePending(ids: notificationIDs)
    }

    /// Re-schedules every restored reminder that is still `.scheduled`.
    ///
    /// Looks each one up fresh rather than trusting the `RestorableReminder`
    /// snapshot: the row could have been edited between the restore and this
    /// call landing, and scheduling a stale title or time would be a second
    /// bug hiding behind the first.
    public func reschedule(_ restorable: [RestorableReminder]) async {
        for candidate in restorable where candidate.status == .scheduled {
            guard let reminder = try? ReminderRepository(database: database).get(id: candidate.id) else { continue }
            await schedule(reminder)
        }
    }
}
