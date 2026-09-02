import Foundation
import GRDB
import ReloraCore

/// Reads and writes for the `contacts` table, ported from the contact-facing
/// functions in apps/mobile/src/db/repositories.ts.
public struct ContactRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// How much history a contact carries — the input to a delete
    /// confirmation decision. Mirrors `ContactContentCounts` in repositories.ts.
    public struct ContentCounts: Equatable, Sendable {
        public var memories: Int
        public var keyThings: Int
        public var reminders: Int

        // Swift synthesizes only an internal memberwise init for a public
        // struct. Spelled out so ReloraFeatures can build the "content count
        // read failed" fallback (M5), and so tests can build fixtures.
        public init(memories: Int, keyThings: Int, reminders: Int) {
            self.memories = memories
            self.keyThings = keyThings
            self.reminders = reminders
        }
    }

    /// Loads active contacts by id, preserving the input order (used to
    /// hydrate search results, whose id order carries the ranking).
    public func getContactsByIDs(_ ids: [String], userID: String) throws -> [Contact] {
        guard !ids.isEmpty else { return [] }
        return try database.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            var arguments: [DatabaseValueConvertible?] = ids.map { $0 as DatabaseValueConvertible? }
            arguments.append(userID)

            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM contacts WHERE id IN (\(placeholders)) AND user_id = ? AND deleted_at IS NULL",
                arguments: StatementArguments(arguments)
            )
            var byID: [String: Contact] = [:]
            for row in rows {
                let contact = try Self.mapContact(row)
                byID[contact.id] = contact
            }
            return ids.compactMap { byID[$0] }
        }
    }

    /// Lists active contacts for a user ordered by update time. Ported LIMIT
    /// 2000 verbatim from `listContacts` — a query bound, not an enforced cap:
    /// nothing rejects contact #2001 on insert, it simply falls out of this
    /// list. See the M2 report for why that distinction matters for the
    /// "caps enforced" test.
    public func list(userID: String) throws -> [Contact] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM contacts WHERE user_id = ? AND deleted_at IS NULL ORDER BY updated_at DESC LIMIT 2000",
                arguments: [userID]
            )
            return try rows.map(Self.mapContact)
        }
    }

    /// Inserts or updates a contact row and marks it dirty for the sync
    /// engine, refreshing its search index row in the same transaction.
    ///
    /// `lastInteractionAt` uses a double-optional to port the `hasOwnProperty`
    /// check in `upsertContact` (repositories.ts): the outer `.none` (the
    /// default, i.e. the argument omitted) means "field not provided — leave
    /// the contact's existing `last_interaction_at` alone", while `.some(x)`
    /// — including `.some(nil)` to explicitly clear it — always overwrites.
    /// Every other field in repositories.ts collapses "not provided" and
    /// "explicitly null" to the same `?? null` write, so those stay plain
    /// optionals here.
    public func upsert(
        id: String,
        userID: String,
        name: String,
        avatarURL: String? = nil,
        descriptors: [String] = [],
        phoneNumber: String? = nil,
        email: String? = nil,
        createdAt: String? = nil,
        lastInteractionAt: String?? = .none,
        deletedAt: String? = nil
    ) throws {
        try database.write { db in
            try Self.write(
                db,
                id: id,
                userID: userID,
                name: name,
                avatarURL: avatarURL,
                descriptors: descriptors,
                phoneNumber: phoneNumber,
                email: email,
                createdAt: createdAt,
                lastInteractionAt: lastInteractionAt,
                deletedAt: deletedAt
            )
        }
    }

    /// The row write on its own, against an already-open connection. See
    /// `MemoryRepository.write` for why this split exists.
    static func write(
        _ db: Database,
        id: String,
        userID: String,
        name: String,
        avatarURL: String? = nil,
        descriptors: [String] = [],
        phoneNumber: String? = nil,
        email: String? = nil,
        createdAt: String? = nil,
        lastInteractionAt: String?? = .none,
        deletedAt: String? = nil
    ) throws {
        let now = ReloraTimestamp.now()
        let created = createdAt ?? now

        let hasLastInteractionAt: Bool
        let lastInteractionValue: String?
        switch lastInteractionAt {
        case .none:
            hasLastInteractionAt = false
            lastInteractionValue = nil
        case .some(let value):
            hasLastInteractionAt = true
            lastInteractionValue = value
        }

        try db.execute(
            sql: """
                INSERT INTO contacts (id, user_id, name, avatar_url, descriptors, phone_number, email, created_at, updated_at, is_dirty, dirty_at, last_interaction_at, deleted_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                 name = excluded.name,
                 avatar_url = excluded.avatar_url,
                 descriptors = excluded.descriptors,
                 phone_number = excluded.phone_number,
                 email = excluded.email,
                 updated_at = excluded.updated_at,
                 is_dirty = 1,
                 dirty_at = excluded.dirty_at,
                 last_interaction_at = CASE
                   WHEN ? = 1 THEN excluded.last_interaction_at
                   ELSE contacts.last_interaction_at
                 END,
                 deleted_at = excluded.deleted_at
                """,
            arguments: [
                id, userID, name, avatarURL, TextJSONArray.encode(descriptors),
                phoneNumber, email, created, now, now, lastInteractionValue, deletedAt,
                hasLastInteractionAt ? 1 : 0
            ]
        )

        ContactSearchIndex.refreshRow(db, contactID: id)
    }

    /// Soft-deletes a contact locally so the delete can be pushed upstream on
    /// the next sync. For deleting a contact along with its children, use
    /// `ContactCascadeDelete.deleteContactCascade` instead.
    public func softDelete(contactID: String, userID: String) throws {
        try database.write { db in
            let deletedAt = ReloraTimestamp.now()
            try db.execute(
                sql: """
                    UPDATE contacts
                    SET deleted_at = ?, updated_at = ?, is_dirty = 1, dirty_at = ?
                    WHERE id = ? AND user_id = ?
                    """,
                arguments: [deletedAt, deletedAt, deletedAt, contactID, userID]
            )
            ContactSearchIndex.refreshRow(db, contactID: contactID)
        }
    }

    /// Counts the live child rows a cascade delete would tombstone. Tombstoned
    /// rows are excluded, so a contact whose history was already deleted
    /// counts as empty.
    public func countContent(contactID: String, userID: String) throws -> ContentCounts {
        try database.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                      (SELECT COUNT(*) FROM memories WHERE contact_id = ? AND user_id = ? AND deleted_at IS NULL) AS memories,
                      (SELECT COUNT(*) FROM key_things WHERE contact_id = ? AND user_id = ? AND deleted_at IS NULL) AS key_things,
                      (SELECT COUNT(*) FROM reminders WHERE contact_id = ? AND user_id = ? AND deleted_at IS NULL) AS reminders
                    """,
                arguments: [contactID, userID, contactID, userID, contactID, userID]
            )
            return ContentCounts(
                memories: row?["memories"] ?? 0,
                keyThings: row?["key_things"] ?? 0,
                reminders: row?["reminders"] ?? 0
            )
        }
    }

    private static func mapContact(_ row: Row) throws -> Contact {
        let isDirtyValue: Int = row["is_dirty"]
        let descriptorsText: String? = row["descriptors"]
        return Contact(
            id: row["id"],
            userID: row["user_id"],
            name: row["name"],
            avatarURL: row["avatar_url"],
            descriptors: try TextJSONArray.decode(descriptorsText),
            phoneNumber: row["phone_number"],
            email: row["email"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            isDirty: isDirtyValue == 1,
            dirtyAt: row["dirty_at"],
            lastInteractionAt: row["last_interaction_at"],
            deletedAt: row["deleted_at"]
        )
    }
}
