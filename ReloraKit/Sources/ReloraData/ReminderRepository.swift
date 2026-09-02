import Foundation
import GRDB
import ReloraCore

/// Reads and writes for the `reminders` table, ported from the reminder-
/// facing functions in apps/mobile/src/db/repositories.ts.
///
/// `upsertReminder` in the RN source interleaves persistence with OS
/// notification scheduling (deciding whether to keep/cancel/reschedule a
/// notification, calling `expo-notifications`, rolling back the schedule if
/// the SQLite write then fails). `ReloraData` depends on nothing but GRDB, so
/// that orchestration is not here — it belongs to ReloraServices/
/// ReloraFeatures, which depend on this module. `get(id:)` exposes the full
/// row (notification_id included) that orchestration needs to make its
/// keep/cancel/reschedule decision before calling `upsert`.
public struct ReminderRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Inserts or updates a reminder row. Throws `ReloraDataError
    /// .reminderMemoryMismatch` when `memoryID` is set but does not name a
    /// row under the same `contactID`/`userID` — mirrors
    /// `assertReminderMemoryLink` in repositories.ts. A tombstoned memory
    /// still satisfies the check: the composite foreign key only needs the
    /// row to exist, not be live, so completing/editing a reminder never
    /// fails just because its source memory was later deleted.
    public func upsert(_ reminder: Reminder) throws {
        try database.write { db in
            try Self.write(db, reminder)
        }
    }

    /// The row write (link assertion included) on its own, against an
    /// already-open connection. See `MemoryRepository.write` for why this
    /// split exists — for a reminder it matters twice over, since the memory
    /// its `memory_id` points at is written in the same transaction and the
    /// assertion would fail against a connection that has not seen it yet.
    static func write(_ db: Database, _ reminder: Reminder) throws {
        try assertMemoryLink(db, reminder: reminder)

        let dirtyAt = ReloraTimestamp.now()
        try db.execute(
            sql: """
                INSERT INTO reminders (id, contact_id, user_id, memory_id, title, remind_at, status, created_at, updated_at, is_dirty, dirty_at, deleted_at, notification_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                 title = excluded.title,
                 remind_at = excluded.remind_at,
                 status = excluded.status,
                 updated_at = excluded.updated_at,
                 is_dirty = 1,
                 dirty_at = excluded.dirty_at,
                 deleted_at = excluded.deleted_at,
                 notification_id = excluded.notification_id
                """,
            arguments: [
                reminder.id, reminder.contactID, reminder.userID, reminder.memoryID,
                reminder.title, reminder.remindAt, reminder.status.rawValue,
                reminder.createdAt, reminder.updatedAt, dirtyAt, reminder.deletedAt, reminder.notificationID
            ]
        )
    }

    /// Fetches one reminder's full row, including `notification_id` and
    /// `is_dirty`/`dirty_at` — unlike `list`/`listByUser`, which project a
    /// narrower column set. Used by callers deciding how to handle an
    /// existing OS notification before an `upsert`.
    public func get(id: String) throws -> Reminder? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, contact_id, user_id, memory_id, title, remind_at, status, created_at, updated_at, is_dirty, dirty_at, deleted_at, notification_id
                    FROM reminders WHERE id = ?
                    """,
                arguments: [id]
            ) else {
                return nil
            }
            return try Self.mapFullReminder(row)
        }
    }

    /// Lists active reminders for a contact ordered by reminder time. Ported
    /// LIMIT 1000 verbatim from `listReminders` — a query bound, not an
    /// enforced cap. The column list intentionally omits `is_dirty`,
    /// `dirty_at`, and `notification_id`, exactly as `listReminders` does (it
    /// is a display list, not a full row hydration) — mapped rows carry the
    /// `Reminder` struct's defaults (`isDirty: false`, `dirtyAt: nil`,
    /// `notificationID: nil`) for those fields rather than their real values.
    public func list(contactID: String) throws -> [Reminder] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, contact_id, user_id, memory_id, title, remind_at, status, created_at, updated_at, deleted_at
                    FROM reminders WHERE contact_id = ? AND deleted_at IS NULL ORDER BY remind_at ASC LIMIT 1000
                    """,
                arguments: [contactID]
            )
            return try rows.map(Self.mapListReminder)
        }
    }

    /// Lists all active reminders for a user in one query (avoids N+1
    /// per-contact queries). Same column-omission note as `list`, and the
    /// same "LIMIT is a query bound, not an enforced cap" note, at 10000.
    public func listByUser(userID: String) throws -> [Reminder] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, contact_id, user_id, memory_id, title, remind_at, status, created_at, updated_at, deleted_at
                    FROM reminders WHERE user_id = ? AND deleted_at IS NULL ORDER BY remind_at ASC LIMIT 10000
                    """,
                arguments: [userID]
            )
            return try rows.map(Self.mapListReminder)
        }
    }

    /// Tombstones a single reminder. See `ContactItemStore.softDelete`.
    public func softDelete(itemID: String, contactID: String, userID: String) throws -> ContactItemDeleteResult {
        try database.write { db in
            try ContactItemStore.softDelete(db, kind: .reminder, itemID: itemID, contactID: contactID, userID: userID)
        }
    }

    /// Restores a single tombstoned reminder. See `ContactItemStore.restore`.
    public func restore(itemID: String, contactID: String, userID: String, deletedAt: String) throws -> ContactItemRestoreResult {
        try database.write { db in
            try ContactItemStore.restore(db, kind: .reminder, itemID: itemID, contactID: contactID, userID: userID, deletedAt: deletedAt)
        }
    }

    /// Full active rows for a user, `notification_id` included — what
    /// `NotificationReconciler` (ReloraServices) and the reminders screen both
    /// need. Same "LIMIT is a query bound, not an enforced cap" note as
    /// `listByUser`, at 10000.
    public func listFullByUser(userID: String) throws -> [Reminder] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, contact_id, user_id, memory_id, title, remind_at, status, created_at, updated_at, is_dirty, dirty_at, deleted_at, notification_id
                    FROM reminders WHERE user_id = ? AND deleted_at IS NULL ORDER BY remind_at ASC LIMIT 10000
                    """,
                arguments: [userID]
            )
            return try rows.map(Self.mapFullReminder)
        }
    }

    /// Sets `notification_id` on one row directly by its own id. Step 2 of
    /// scheduling a single reminder — the caller has already asked the OS to
    /// schedule the notification and is recording the id it got back.
    ///
    /// Deliberately does **not** mark the row dirty, for the same reason as
    /// `clearNotificationIDs`: `notification_id` is local-only.
    public func setNotificationID(_ reminderID: String, notificationID: String?) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE reminders SET notification_id = ? WHERE id = ?",
                arguments: [notificationID, reminderID]
            )
        }
    }

    /// Clears `notification_id` on the reminders holding these ids.
    ///
    /// Step 2 of the two-step ordering in `docs/milestone-notes.md`: a sync pull
    /// that tombstones a reminder surfaces its notification id, the caller
    /// cancels the OS notification, and only then does this run. Reversing the
    /// two leaves a scheduled notification with no row behind it, which fires as
    /// a reminder about something the user already deleted.
    ///
    /// Deliberately does **not** mark the row dirty. `notification_id` is
    /// local-only — `RowTransforms` strips it from every push — so writing it
    /// is not a change the server needs to hear about, and dirtying the row here
    /// would queue an empty upload after every pull.
    public func clearNotificationIDs(_ notificationIDs: [String]) throws {
        guard !notificationIDs.isEmpty else { return }
        try database.write { db in
            let placeholders = notificationIDs.map { _ in "?" }.joined(separator: ", ")
            try db.execute(
                sql: "UPDATE reminders SET notification_id = NULL WHERE notification_id IN (\(placeholders))",
                arguments: StatementArguments(notificationIDs.map { $0 as DatabaseValueConvertible? })
            )
        }
    }

    private static func assertMemoryLink(_ db: Database, reminder: Reminder) throws {
        guard let memoryID = reminder.memoryID else { return }
        let matchExists = try Row.fetchOne(
            db,
            sql: "SELECT id FROM memories WHERE id = ? AND contact_id = ? AND user_id = ? LIMIT 1",
            arguments: [memoryID, reminder.contactID, reminder.userID]
        ) != nil
        guard matchExists else {
            throw ReloraDataError.reminderMemoryMismatch
        }
    }

    private static func mapListReminder(_ row: Row) throws -> Reminder {
        guard let status = ReminderStatus(rawValue: row["status"] as String) else {
            throw ReloraDataError.invalidRow("reminders.status")
        }
        return Reminder(
            id: row["id"],
            contactID: row["contact_id"],
            userID: row["user_id"],
            memoryID: row["memory_id"],
            title: row["title"],
            remindAt: row["remind_at"],
            status: status,
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            deletedAt: row["deleted_at"]
        )
    }

    private static func mapFullReminder(_ row: Row) throws -> Reminder {
        guard let status = ReminderStatus(rawValue: row["status"] as String) else {
            throw ReloraDataError.invalidRow("reminders.status")
        }
        let isDirtyValue: Int = row["is_dirty"]
        return Reminder(
            id: row["id"],
            contactID: row["contact_id"],
            userID: row["user_id"],
            memoryID: row["memory_id"],
            title: row["title"],
            remindAt: row["remind_at"],
            status: status,
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            isDirty: isDirtyValue == 1,
            dirtyAt: row["dirty_at"],
            notificationID: row["notification_id"],
            deletedAt: row["deleted_at"]
        )
    }
}
