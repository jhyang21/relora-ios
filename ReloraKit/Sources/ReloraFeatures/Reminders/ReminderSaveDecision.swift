import Foundation
import ReloraCore

/// Whether a reminder write needs a fresh OS notification, can keep the one
/// it already has, or needs none at all. Ports the notification half of
/// `upsertReminder` in `apps/mobile/src/db/repositories.ts` — the row write
/// itself is `ReminderRepository.upsert` (ReloraData), which does not touch
/// notifications at all; see that repository's own doc comment for why the
/// split exists.
public enum ReminderScheduleDecision: Equatable, Sendable {
    /// The existing notification already matches this write in everything
    /// that would change its content — time, title, contact — and is still
    /// live. Leave it alone.
    case keep(notificationID: String)
    /// Mint a fresh notification before the row is written.
    case scheduleNew
    /// Write with no notification id: disabled, already past, or not
    /// `.scheduled`.
    case none
}

public enum ReminderScheduling {
    /// `existing` is the row's state before this write (`nil` for a
    /// brand-new reminder — always the case from `AddReminderViewModel`,
    /// which mints a fresh id per save; kept general here for a future edit
    /// path, per the M8b report). `candidate` is the value about to be
    /// written; its `notificationID` is ignored on the way in — this
    /// function decides that field, it does not read it.
    public static func decide(
        existing: Reminder?,
        candidate: Reminder,
        notificationsEnabled: Bool,
        now: Date = Date()
    ) -> ReminderScheduleDecision {
        let isFuture: Bool = {
            guard candidate.status == .scheduled, candidate.deletedAt == nil,
                  let remindAt = ReloraTimestamp.parse(candidate.remindAt) else { return false }
            return remindAt > now
        }()
        let shouldSchedule = notificationsEnabled && isFuture

        // Ports `existingIsScheduled`. The empty-string guard mirrors RN's
        // `!!existing?.notification_id`, which is also false for an empty
        // string under JS truthiness — not just null/undefined.
        let existingIsScheduled: Bool = {
            guard let existing, let notificationID = existing.notificationID, !notificationID.isEmpty else {
                return false
            }
            return existing.status == .scheduled
                && existing.deletedAt == nil
                && existing.remindAt == candidate.remindAt
                && existing.title == candidate.title
                && existing.contactID == candidate.contactID
        }()

        if shouldSchedule, existingIsScheduled, let notificationID = existing?.notificationID {
            return .keep(notificationID: notificationID)
        }
        if shouldSchedule {
            return .scheduleNew
        }
        return .none
    }
}
