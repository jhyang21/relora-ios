import Foundation
import GRDB
import ReloraCore

/// Reads and writes for the `memories` table, ported from the memory-facing
/// functions in apps/mobile/src/db/repositories.ts.
public struct MemoryRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Inserts or updates a memory row and refreshes the related contact's
    /// search index row in the same transaction.
    ///
    /// `audio_local_uri` is COALESCEd against the existing row on conflict —
    /// ported verbatim from `upsertMemory` in repositories.ts — because it is
    /// mobile-only replay metadata written by a later, separate step (once the
    /// file finishes downloading) than the memory row itself; an upsert that
    /// does not carry a local URI yet must not overwrite one a previous write
    /// already recorded.
    public func upsert(_ memory: Memory) throws {
        try database.write { db in
            try Self.write(db, memory)
        }
    }

    /// The row write on its own, against an already-open connection.
    ///
    /// Same shape and rationale as `ContactSearchIndex.refreshRow`: a caller
    /// that is already inside an `AppDatabase.write` block — `VoiceCaptureWrite`,
    /// which has to land a memory, its key things, a reminder and a usage event
    /// or none of them — needs the statement without a second transaction
    /// around it. `upsert` above is this plus the transaction.
    static func write(_ db: Database, _ memory: Memory) throws {
        let dirtyAt = ReloraTimestamp.now()
        try db.execute(
            sql: """
                INSERT INTO memories (id, contact_id, user_id, text, labels, created_at, updated_at, is_dirty, dirty_at, audio_url, audio_local_uri, transcript, source, deleted_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                 text = excluded.text,
                 labels = excluded.labels,
                 updated_at = excluded.updated_at,
                 is_dirty = 1,
                 dirty_at = excluded.dirty_at,
                 audio_url = excluded.audio_url,
                 audio_local_uri = COALESCE(excluded.audio_local_uri, memories.audio_local_uri),
                 transcript = excluded.transcript,
                 source = excluded.source,
                 deleted_at = excluded.deleted_at
                """,
            arguments: [
                memory.id, memory.contactID, memory.userID, memory.text, TextJSONArray.encode(memory.labels),
                memory.createdAt, memory.updatedAt, dirtyAt, memory.audioURL, memory.audioLocalURI,
                memory.transcript, memory.source.rawValue, memory.deletedAt
            ]
        )

        // Reads back contact_id rather than trusting memory.contactID
        // directly, matching repositories.ts's own re-fetch after write.
        let contactID: String
        if let row = try Row.fetchOne(db, sql: "SELECT contact_id FROM memories WHERE id = ?", arguments: [memory.id]) {
            contactID = row["contact_id"]
        } else {
            contactID = memory.contactID
        }
        ContactSearchIndex.refreshRow(db, contactID: contactID)
    }

    /// Lists active memories for a contact in reverse creation order.
    public func list(contactID: String) throws -> [Memory] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM memories WHERE contact_id = ? AND deleted_at IS NULL ORDER BY created_at DESC",
                arguments: [contactID]
            )
            return try rows.map(Self.mapMemory)
        }
    }

    /// Every `audio_local_uri` a live memory still points at.
    ///
    /// Spans every `user_id` on purpose. Recordings are per-device files
    /// with no owner, and guest-to-account migration re-owns rows without
    /// touching the files, so a per-user filter would let the sweep delete
    /// the other identity's recordings.
    ///
    /// Throws on a read failure instead of returning an empty set: the
    /// caller must be able to tell "nothing is referenced" from "the
    /// references could not be read". The first licenses deletion, the
    /// second forbids it.
    public func liveAudioLocalURIs() throws -> Set<String> {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT audio_local_uri FROM memories
                    WHERE deleted_at IS NULL
                      AND audio_local_uri IS NOT NULL
                      AND TRIM(audio_local_uri) <> ''
                    """
            )
            return Set(rows.compactMap { row -> String? in row["audio_local_uri"] })
        }
    }

    /// Tombstones a single memory. See `ContactItemStore.softDelete` for the
    /// shared soft-delete semantics.
    public func softDelete(itemID: String, contactID: String, userID: String) throws -> ContactItemDeleteResult {
        try database.write { db in
            try ContactItemStore.softDelete(db, kind: .memory, itemID: itemID, contactID: contactID, userID: userID)
        }
    }

    /// Restores a single tombstoned memory. See `ContactItemStore.restore`.
    public func restore(itemID: String, contactID: String, userID: String, deletedAt: String) throws -> ContactItemRestoreResult {
        try database.write { db in
            try ContactItemStore.restore(db, kind: .memory, itemID: itemID, contactID: contactID, userID: userID, deletedAt: deletedAt)
        }
    }

    private static func mapMemory(_ row: Row) throws -> Memory {
        let isDirtyValue: Int = row["is_dirty"]
        let sourceRaw: String = row["source"]
        guard let source = EntrySource(rawValue: sourceRaw) else {
            throw ReloraDataError.invalidRow("memories.source")
        }
        let labelsText: String? = row["labels"]
        return Memory(
            id: row["id"],
            contactID: row["contact_id"],
            userID: row["user_id"],
            text: row["text"],
            labels: try TextJSONArray.decode(labelsText),
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            isDirty: isDirtyValue == 1,
            dirtyAt: row["dirty_at"],
            audioURL: row["audio_url"],
            audioLocalURI: row["audio_local_uri"],
            transcript: row["transcript"],
            source: source,
            deletedAt: row["deleted_at"]
        )
    }
}
