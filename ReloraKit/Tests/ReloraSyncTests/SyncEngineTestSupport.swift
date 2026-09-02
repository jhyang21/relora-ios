import Foundation
import GRDB
import ReloraCore
import ReloraData
@testable import ReloraSync

/// An in-memory `SyncTransport` standing in for the network: `serverRows`
/// is the fake backend's dataset per table (must be pre-sorted by
/// `(updated_at, id)`, matching what a real `order=updated_at.asc,id.asc`
/// response would return), `pull` filters and pages it exactly like
/// PostgREST would, and `upsert` just records what was pushed (optionally
/// throwing a queued error, or running a hook that can mutate the local
/// database mid-push to simulate a concurrent edit).
actor StubSyncTransport: SyncTransport {
    struct PullQuery: Sendable, Equatable {
        var table: SyncTable
        var userID: String
        var updatedAfter: String?
        var from: Int
        var to: Int
    }

    private(set) var upsertedBatches: [SyncTable: [[JSONObject]]] = [:]
    private(set) var upsertCallOrder: [SyncTable] = []
    private(set) var pullQueries: [PullQuery] = []

    var serverRows: [SyncTable: [JSONObject]] = [:]
    /// Typed as the concrete `BackendError` (not `any Error`) so it stays
    /// `Sendable` and can be thrown back across the actor boundary cleanly
    /// under strict concurrency — every real transport error is a
    /// `BackendError` anyway (see `PostgRESTLite`).
    var upsertErrorQueue: [SyncTable: [BackendError]] = [:]
    /// Runs synchronously inside `upsert`, before recording the call —
    /// lets a test simulate a local write racing the in-flight push.
    var onUpsert: (@Sendable (SyncTable, [JSONObject]) async throws -> Void)?

    func upsert(table: SyncTable, rows: [JSONObject], onConflict: String) async throws {
        if var queue = upsertErrorQueue[table], !queue.isEmpty {
            let error = queue.removeFirst()
            upsertErrorQueue[table] = queue
            throw error
        }
        try await onUpsert?(table, rows)
        upsertedBatches[table, default: []].append(rows)
        upsertCallOrder.append(table)
    }

    func pull(
        table: SyncTable,
        userID: String,
        updatedAfter: String?,
        range: (from: Int, to: Int)
    ) async throws -> [JSONObject] {
        pullQueries.append(PullQuery(table: table, userID: userID, updatedAfter: updatedAfter, from: range.from, to: range.to))

        let matching = (serverRows[table] ?? []).filter { row in
            guard case .string(let rowUserID)? = row["user_id"], rowUserID == userID else { return false }
            guard let updatedAfter else { return true }
            guard case .string(let updatedAt)? = row["updated_at"] else { return true }
            return updatedAt > updatedAfter
        }
        guard range.from < matching.count else { return [] }
        let end = min(range.to + 1, matching.count)
        return Array(matching[range.from..<end])
    }
}

let testUserID = "user-1"

/// Direct SQL seeding, bypassing the ReloraData repositories on purpose:
/// the repositories always force `is_dirty = 1` / a fresh `dirty_at` on
/// write, which would make it impossible to construct the precise
/// dirty/clean fixtures these tests need (a clean row with a chosen
/// `updated_at`, a dirty row with a chosen `dirty_at` ordering, ...).
enum SyncFixtures {
    static func insertContact(
        _ db: Database,
        id: String,
        userID: String = testUserID,
        name: String = "Ada",
        descriptors: [String] = [],
        updatedAt: String,
        isDirty: Bool = false,
        dirtyAt: String? = nil,
        deletedAt: String? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO contacts (id, user_id, name, descriptors, created_at, updated_at, is_dirty, dirty_at, deleted_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [id, userID, name, TextJSONArray.encode(descriptors), updatedAt, updatedAt, isDirty ? 1 : 0, dirtyAt, deletedAt]
        )
    }

    static func insertMemory(
        _ db: Database,
        id: String,
        contactID: String,
        userID: String = testUserID,
        text: String = "met for coffee",
        labels: [String] = [],
        updatedAt: String,
        isDirty: Bool = false,
        dirtyAt: String? = nil,
        deletedAt: String? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO memories (id, contact_id, user_id, text, labels, created_at, updated_at, is_dirty, dirty_at, source, deleted_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'manual', ?)
                """,
            arguments: [id, contactID, userID, text, TextJSONArray.encode(labels), updatedAt, updatedAt, isDirty ? 1 : 0, dirtyAt, deletedAt]
        )
    }

    static func insertReminder(
        _ db: Database,
        id: String,
        contactID: String,
        userID: String = testUserID,
        title: String = "follow up",
        remindAt: String,
        updatedAt: String,
        isDirty: Bool = false,
        dirtyAt: String? = nil,
        notificationID: String? = nil,
        deletedAt: String? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO reminders (id, contact_id, user_id, title, remind_at, status, created_at, updated_at, is_dirty, dirty_at, notification_id, deleted_at)
                VALUES (?, ?, ?, ?, ?, 'scheduled', ?, ?, ?, ?, ?, ?)
                """,
            arguments: [id, contactID, userID, title, remindAt, updatedAt, updatedAt, isDirty ? 1 : 0, dirtyAt, notificationID, deletedAt]
        )
    }

    static func isDirty(_ db: Database, table: SyncTable, id: String) throws -> Bool {
        let value = try Int.fetchOne(db, sql: "SELECT is_dirty FROM \(table.rawValue) WHERE id = ?", arguments: [id])
        return value == 1
    }

    static func dirtyCount(_ db: Database, table: SyncTable) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.rawValue) WHERE is_dirty = 1") ?? 0
    }

    static func column(_ db: Database, table: SyncTable, id: String, column: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT \(column) FROM \(table.rawValue) WHERE id = ?", arguments: [id])
    }
}

/// Builds a PostgREST-shaped server row for `contacts`, matching the server
/// schema's column set exactly (no `is_dirty`/`dirty_at`/local-only columns —
/// see `RowTransforms.localOnlyColumns`).
func serverContactRow(
    id: String,
    userID: String = testUserID,
    name: String = "Ada",
    descriptors: [String] = [],
    updatedAt: String,
    deletedAt: String? = nil
) -> JSONObject {
    [
        "id": .string(id),
        "user_id": .string(userID),
        "name": .string(name),
        "avatar_url": .null,
        "descriptors": .array(descriptors.map { .string($0) }),
        "phone_number": .null,
        "email": .null,
        "created_at": .string(updatedAt),
        "updated_at": .string(updatedAt),
        "last_interaction_at": .null,
        "deleted_at": deletedAt.map { .string($0) } ?? .null
    ]
}

func serverMemoryRow(
    id: String,
    contactID: String,
    userID: String = testUserID,
    text: String = "met for coffee",
    labels: [String] = [],
    updatedAt: String,
    deletedAt: String? = nil
) -> JSONObject {
    [
        "id": .string(id),
        "contact_id": .string(contactID),
        "user_id": .string(userID),
        "text": .string(text),
        "labels": .array(labels.map { .string($0) }),
        "created_at": .string(updatedAt),
        "updated_at": .string(updatedAt),
        "audio_url": .null,
        "transcript": .null,
        "source": .string("manual"),
        "deleted_at": deletedAt.map { .string($0) } ?? .null
    ]
}

func serverReminderRow(
    id: String,
    contactID: String,
    userID: String = testUserID,
    title: String = "follow up",
    remindAt: String,
    updatedAt: String,
    deletedAt: String? = nil
) -> JSONObject {
    [
        "id": .string(id),
        "contact_id": .string(contactID),
        "user_id": .string(userID),
        "memory_id": .null,
        "title": .string(title),
        "remind_at": .string(remindAt),
        "status": .string("scheduled"),
        "created_at": .string(updatedAt),
        "updated_at": .string(updatedAt),
        "deleted_at": deletedAt.map { .string($0) } ?? .null
    ]
}
