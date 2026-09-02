import Foundation
import GRDB
import ReloraCore

/// Reads and writes for the `key_things` table, ported from the key-thing-
/// facing functions in apps/mobile/src/db/repositories.ts. NOTE: unlike
/// `Memory`, a key thing has no `labels` column — see `ReloraCore.KeyThing`.
public struct KeyThingRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Inserts or updates a key thing and refreshes the contact's search
    /// index row in the same transaction.
    public func upsert(_ item: KeyThing) throws {
        try database.write { db in
            try Self.write(db, item)
        }
    }

    /// The row write on its own, against an already-open connection. See
    /// `MemoryRepository.write` for why this split exists.
    static func write(_ db: Database, _ item: KeyThing) throws {
        let dirtyAt = ReloraTimestamp.now()
        try db.execute(
            sql: """
                INSERT INTO key_things (id, contact_id, user_id, text, source, created_at, updated_at, is_dirty, dirty_at, deleted_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                 text = excluded.text,
                 source = excluded.source,
                 updated_at = excluded.updated_at,
                 is_dirty = 1,
                 dirty_at = excluded.dirty_at,
                 deleted_at = excluded.deleted_at
                """,
            arguments: [
                item.id, item.contactID, item.userID, item.text, item.source.rawValue,
                item.createdAt, item.updatedAt, dirtyAt, item.deletedAt
            ]
        )

        let contactID: String
        if let row = try Row.fetchOne(db, sql: "SELECT contact_id FROM key_things WHERE id = ?", arguments: [item.id]) {
            contactID = row["contact_id"]
        } else {
            contactID = item.contactID
        }
        ContactSearchIndex.refreshRow(db, contactID: contactID)
    }

    /// Lists active key things for a contact in reverse update order.
    public func list(contactID: String) throws -> [KeyThing] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM key_things WHERE contact_id = ? AND deleted_at IS NULL ORDER BY updated_at DESC",
                arguments: [contactID]
            )
            return try rows.map(Self.mapKeyThing)
        }
    }

    /// Tombstones a single key thing. See `ContactItemStore.softDelete`.
    public func softDelete(itemID: String, contactID: String, userID: String) throws -> ContactItemDeleteResult {
        try database.write { db in
            try ContactItemStore.softDelete(db, kind: .keyThing, itemID: itemID, contactID: contactID, userID: userID)
        }
    }

    /// Restores a single tombstoned key thing. See `ContactItemStore.restore`.
    public func restore(itemID: String, contactID: String, userID: String, deletedAt: String) throws -> ContactItemRestoreResult {
        try database.write { db in
            try ContactItemStore.restore(db, kind: .keyThing, itemID: itemID, contactID: contactID, userID: userID, deletedAt: deletedAt)
        }
    }

    private static func mapKeyThing(_ row: Row) throws -> KeyThing {
        let isDirtyValue: Int = row["is_dirty"]
        let sourceRaw: String = row["source"]
        guard let source = EntrySource(rawValue: sourceRaw) else {
            throw ReloraDataError.invalidRow("key_things.source")
        }
        return KeyThing(
            id: row["id"],
            contactID: row["contact_id"],
            userID: row["user_id"],
            text: row["text"],
            source: source,
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            isDirty: isDirtyValue == 1,
            dirtyAt: row["dirty_at"],
            deletedAt: row["deleted_at"]
        )
    }
}
