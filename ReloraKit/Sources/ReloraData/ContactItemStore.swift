import Foundation
import GRDB
import ReloraCore

/// The three item kinds a user can delete from inside a contact. Kept as a
/// closed enum, mirroring the closed `ContactItemKind` union in
/// repositories.ts, so the table name is never built from caller-supplied text.
public enum ContactItemKind: String, Equatable, Sendable {
    case memory
    case keyThing = "key_thing"
    case reminder

    var table: String {
        switch self {
        case .memory: return "memories"
        case .keyThing: return "key_things"
        case .reminder: return "reminders"
        }
    }
}

/// A reminder captured before its tombstone was cleared, carrying just enough
/// to decide whether (and how) to re-schedule its OS notification. ReloraData
/// has no dependency on any notification framework, so — unlike
/// `restoreContactItem` in repositories.ts, which reschedules inline — the
/// scheduling decision belongs to a higher layer (ReloraServices/ReloraFeatures);
/// this type is what that layer needs to make it.
public struct RestorableReminder: Equatable, Sendable {
    public var id: String
    public var contactID: String
    public var title: String
    public var remindAt: String
    public var status: ReminderStatus

    // Explicit and public: the auto-synthesized memberwise initializer a
    // struct gets for free is only ever `internal`, whatever access level
    // the type itself declares. Every existing construction site
    // (`ContactItemStore`, `CascadeDelete`) is inside this module and never
    // noticed; M8's `RemindersViewModel` (ReloraFeatures) is the first
    // caller across the module boundary, for a reminder marked done rather
    // than deleted — there is no `ContactItemRestoreResult` to hand it one
    // ready-made, so it has to build this itself.
    public init(id: String, contactID: String, title: String, remindAt: String, status: ReminderStatus) {
        self.id = id
        self.contactID = contactID
        self.title = title
        self.remindAt = remindAt
        self.status = status
    }
}

/// Result of a single-item soft delete.
public struct ContactItemDeleteResult: Equatable, Sendable {
    public var deletedAt: String
    /// Whether this call was the one that tombstoned the row — a repeat call
    /// with a stale expectation matches nothing and reports `false`.
    public var deleted: Bool
    /// Notification ids the caller should cancel, non-empty only for a
    /// reminder that was actually deleted and had one scheduled.
    public var canceledNotificationIDs: [String]
}

/// Result of a single-item restore.
public struct ContactItemRestoreResult: Equatable, Sendable {
    public var restored: Bool
    /// The restored reminder, when this item was one — returned whatever its
    /// status or `remindAt`, same as `ContactCascadeDelete.restoreContactCascade`.
    /// Whether it should actually get an OS notification (still `scheduled`,
    /// in the future, notifications enabled) is the caller's policy decision.
    public var reminderToReschedule: RestorableReminder?
}

/// Shared soft-delete/restore engine behind `ContactRepository`,
/// `MemoryRepository`, `KeyThingRepository`, and `ReminderRepository`'s
/// single-item operations, ported from `softDeleteContactItem`/
/// `restoreContactItem` in repositories.ts. One implementation for all three
/// tables keeps the "exact tombstone timestamp as undo handle" invariant from
/// drifting between them.
enum ContactItemStore {
    /// Tombstones a single memory, key thing, or reminder. Like the contact
    /// cascade, this soft-deletes rather than hard-deletes, so the sync engine
    /// can push the tombstone upstream.
    ///
    /// Two behaviors fall out of tombstoning instead of deleting, exactly as
    /// in repositories.ts:
    /// - `contacts.last_interaction_at` is recomputed by the `AFTER UPDATE`
    ///   triggers on `memories`/`key_things` (they only count rows with
    ///   `deleted_at IS NULL`). Reminders never feed last-interaction, so
    ///   nothing recomputes there.
    /// - A reminder linked to a deleted memory keeps its `memory_id`: the
    ///   memory row still exists, so the composite foreign key stays valid and
    ///   undo restores the pairing untouched.
    static func softDelete(
        _ db: Database,
        kind: ContactItemKind,
        itemID: String,
        contactID: String,
        userID: String
    ) throws -> ContactItemDeleteResult {
        let deletedAt = ReloraTimestamp.now()
        let isReminder = kind == .reminder

        var notificationIDs: [String] = []
        if isReminder {
            // Capture before the UPDATE clears notification_id.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT notification_id FROM reminders
                    WHERE id = ? AND contact_id = ? AND user_id = ? AND deleted_at IS NULL AND notification_id IS NOT NULL
                    """,
                arguments: [itemID, contactID, userID]
            )
            notificationIDs = rows.compactMap { row -> String? in row["notification_id"] }
        }

        let notificationClearClause = isReminder ? ", notification_id = NULL" : ""
        try db.execute(
            sql: """
                UPDATE \(kind.table)
                SET deleted_at = ?, updated_at = ?, is_dirty = 1, dirty_at = ?\(notificationClearClause)
                WHERE id = ? AND contact_id = ? AND user_id = ? AND deleted_at IS NULL
                """,
            arguments: [deletedAt, deletedAt, deletedAt, itemID, contactID, userID]
        )
        let deleted = db.changesCount > 0

        if !isReminder {
            ContactSearchIndex.refreshRow(db, contactID: contactID)
        }

        return ContactItemDeleteResult(
            deletedAt: deletedAt,
            deleted: deleted,
            canceledNotificationIDs: deleted ? notificationIDs : []
        )
    }

    /// Undoes a `softDelete` by clearing the tombstone that carries its exact
    /// timestamp, so it can never resurrect a row deleted at any other time and
    /// a repeated call matches zero rows.
    ///
    /// Refuses when the parent contact is tombstoned. The two undo windows can
    /// overlap: delete an item, then delete the whole contact before the
    /// item's undo toast expires. `ContactCascadeDelete` only stamps rows with
    /// `deleted_at IS NULL`, so it leaves the item's older tombstone alone and
    /// the timestamp still matches — restoring here would leave a live row
    /// under a dead parent, hidden from every UI query and pushed upstream as
    /// an orphan.
    static func restore(
        _ db: Database,
        kind: ContactItemKind,
        itemID: String,
        contactID: String,
        userID: String,
        deletedAt: String
    ) throws -> ContactItemRestoreResult {
        let isReminder = kind == .reminder
        let now = ReloraTimestamp.now()

        let liveContactExists = try Row.fetchOne(
            db,
            sql: "SELECT id FROM contacts WHERE id = ? AND user_id = ? AND deleted_at IS NULL",
            arguments: [contactID, userID]
        ) != nil
        guard liveContactExists else {
            return ContactItemRestoreResult(restored: false, reminderToReschedule: nil)
        }

        var reminderToRestore: RestorableReminder?
        if isReminder {
            // Read before the tombstone is cleared so a repeated call finds nothing.
            if let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, contact_id, title, remind_at, status FROM reminders
                    WHERE id = ? AND contact_id = ? AND user_id = ? AND deleted_at = ?
                    """,
                arguments: [itemID, contactID, userID, deletedAt]
            ) {
                let statusRaw: String = row["status"]
                guard let status = ReminderStatus(rawValue: statusRaw) else {
                    throw ReloraDataError.invalidRow("reminders.status")
                }
                reminderToRestore = RestorableReminder(
                    id: row["id"],
                    contactID: row["contact_id"],
                    title: row["title"],
                    remindAt: row["remind_at"],
                    status: status
                )
            }
        }

        try db.execute(
            sql: """
                UPDATE \(kind.table)
                SET deleted_at = NULL, updated_at = ?, is_dirty = 1, dirty_at = ?
                WHERE id = ? AND contact_id = ? AND user_id = ? AND deleted_at = ?
                """,
            arguments: [now, now, itemID, contactID, userID, deletedAt]
        )
        let restored = db.changesCount > 0

        if !isReminder {
            ContactSearchIndex.refreshRow(db, contactID: contactID)
        }

        // Returned regardless of status/remindAt — same as
        // ContactCascadeDelete.restoreContactCascade, which hands back every
        // restored reminder unfiltered. Whether a given reminder is still
        // `.scheduled` and in the future (and whether notifications are even
        // enabled) is a runtime policy decision the caller makes, not a fact
        // ReloraData can settle on its own.
        return ContactItemRestoreResult(restored: restored, reminderToReschedule: restored ? reminderToRestore : nil)
    }
}
