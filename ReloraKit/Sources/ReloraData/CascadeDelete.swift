import Foundation
import GRDB
import ReloraCore

/// Result of `ContactCascadeDelete.deleteContactCascade`. `deletedAt` is the
/// undo handle: `restoreContactCascade` un-tombstones exactly the rows this
/// delete stamped, and nothing else.
public struct ContactCascadeDeleteResult: Equatable, Sendable {
    public var deletedAt: String
    /// Notification ids the caller should cancel — every reminder under the
    /// contact that had one, regardless of the reminder's own `deleted_at`
    /// (mirrors the RN query, which reads `notification_id IS NOT NULL` with
    /// no `deleted_at` filter, since the goal is "kill every OS notification
    /// this contact still owns").
    public var canceledNotificationIDs: [String]
}

public struct ContactCascadeRestoreResult: Equatable, Sendable {
    public var restoredContact: Bool
    /// Every reminder whose tombstone was just cleared by this restore. The
    /// caller (ReloraServices/ReloraFeatures) decides which of these are still
    /// `scheduled` and in the future, checks the notifications-enabled
    /// setting, and re-schedules — ReloraData has no notification-framework
    /// dependency to do that itself.
    public var remindersToReschedule: [RestorableReminder]
}

/// Whole-contact cascade delete/restore, ported from `deleteContactCascade`/
/// `restoreContactCascade` in repositories.ts. Unlike `ContactItemStore`, this
/// operates on every child row under a contact at once, sharing ONE tombstone
/// timestamp across reminders → memories → key_things → the contact itself.
public enum ContactCascadeDelete {
    /// Tombstones all local child rows for a contact, then soft-deletes the
    /// contact row, so the sync engine can push every tombstone upstream.
    /// Runs inside its own write transaction.
    public static func deleteContactCascade(
        database: AppDatabase,
        contactID: String,
        userID: String
    ) throws -> ContactCascadeDeleteResult {
        try database.write { db in
            let deletedAt = ReloraTimestamp.now()

            let notificationRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT notification_id FROM reminders
                    WHERE contact_id = ? AND user_id = ? AND notification_id IS NOT NULL
                    """,
                arguments: [contactID, userID]
            )
            let notificationIDs: [String] = notificationRows.compactMap { row -> String? in row["notification_id"] }

            try db.execute(
                sql: """
                    UPDATE reminders
                    SET deleted_at = ?, updated_at = ?, is_dirty = 1, dirty_at = ?, notification_id = NULL
                    WHERE contact_id = ? AND user_id = ? AND deleted_at IS NULL
                    """,
                arguments: [deletedAt, deletedAt, deletedAt, contactID, userID]
            )
            try db.execute(
                sql: """
                    UPDATE memories
                    SET deleted_at = ?, updated_at = ?, is_dirty = 1, dirty_at = ?
                    WHERE contact_id = ? AND user_id = ? AND deleted_at IS NULL
                    """,
                arguments: [deletedAt, deletedAt, deletedAt, contactID, userID]
            )
            try db.execute(
                sql: """
                    UPDATE key_things
                    SET deleted_at = ?, updated_at = ?, is_dirty = 1, dirty_at = ?
                    WHERE contact_id = ? AND user_id = ? AND deleted_at IS NULL
                    """,
                arguments: [deletedAt, deletedAt, deletedAt, contactID, userID]
            )
            // No `deleted_at IS NULL` guard here — matches `softDeleteContactRow`
            // in repositories.ts, which stamps the contact unconditionally.
            try db.execute(
                sql: """
                    UPDATE contacts
                    SET deleted_at = ?, updated_at = ?, is_dirty = 1, dirty_at = ?
                    WHERE id = ? AND user_id = ?
                    """,
                arguments: [deletedAt, deletedAt, deletedAt, contactID, userID]
            )

            ContactSearchIndex.refreshRow(db, contactID: contactID)

            return ContactCascadeDeleteResult(deletedAt: deletedAt, canceledNotificationIDs: notificationIDs)
        }
    }

    /// Undoes a `deleteContactCascade` by clearing tombstones that carry its
    /// exact shared `deletedAt`, so it can never resurrect rows deleted at any
    /// other time — a row tombstoned in an earlier, separate delete keeps its
    /// own (different) timestamp and is left alone — and a second call
    /// against the same handle matches zero rows (idempotent).
    public static func restoreContactCascade(
        database: AppDatabase,
        contactID: String,
        userID: String,
        deletedAt: String
    ) throws -> ContactCascadeRestoreResult {
        try database.write { db in
            let now = ReloraTimestamp.now()

            // Capture BEFORE clearing tombstones so a repeated call finds nothing.
            let reminderRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, contact_id, title, remind_at, status
                    FROM reminders
                    WHERE contact_id = ? AND user_id = ? AND deleted_at = ?
                    """,
                arguments: [contactID, userID, deletedAt]
            )
            let remindersToRestore: [RestorableReminder] = try reminderRows.map { row in
                let statusRaw: String = row["status"]
                guard let status = ReminderStatus(rawValue: statusRaw) else {
                    throw ReloraDataError.invalidRow("reminders.status")
                }
                return RestorableReminder(
                    id: row["id"],
                    contactID: row["contact_id"],
                    title: row["title"],
                    remindAt: row["remind_at"],
                    status: status
                )
            }

            try db.execute(
                sql: """
                    UPDATE contacts
                    SET deleted_at = NULL, updated_at = ?, is_dirty = 1, dirty_at = ?
                    WHERE id = ? AND user_id = ? AND deleted_at = ?
                    """,
                arguments: [now, now, contactID, userID, deletedAt]
            )
            let restoredContact = db.changesCount > 0

            for table in ["memories", "key_things", "reminders"] {
                try db.execute(
                    sql: """
                        UPDATE \(table)
                        SET deleted_at = NULL, updated_at = ?, is_dirty = 1, dirty_at = ?
                        WHERE contact_id = ? AND user_id = ? AND deleted_at = ?
                        """,
                    arguments: [now, now, contactID, userID, deletedAt]
                )
            }

            ContactSearchIndex.refreshRow(db, contactID: contactID)

            return ContactCascadeRestoreResult(
                restoredContact: restoredContact,
                remindersToReschedule: remindersToRestore
            )
        }
    }
}
