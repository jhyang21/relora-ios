import Foundation
import GRDB

/// The `sync_state` singleton row: which user the local store currently
/// belongs to, the server's replication cursor, and when the last sync ran.
public struct SyncState: Equatable, Sendable {
    public var userID: String?
    public var serverCursor: String?
    public var lastSyncAt: String?

    public init(userID: String? = nil, serverCursor: String? = nil, lastSyncAt: String? = nil) {
        self.userID = userID
        self.serverCursor = serverCursor
        self.lastSyncAt = lastSyncAt
    }
}

/// Reads and writes the single `sync_state` row (`CHECK (id = 1)` in the
/// schema; seeded by the v9-baseline migration, so it always exists). No
/// dedicated RN repository module owns this table — apps/mobile reads/writes
/// it inline wherever the sync engine and identity migration need it (see
/// `migrateLocalDataOwnership` in apps/mobile/src/state/localOwnership.ts for
/// the reset shape this ports) — so this store is this port's single owner
/// of that access pattern.
public struct SyncStateStore: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func read() throws -> SyncState {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT user_id, server_cursor, last_sync_at FROM sync_state WHERE id = 1") else {
                return SyncState()
            }
            return SyncState(userID: row["user_id"], serverCursor: row["server_cursor"], lastSyncAt: row["last_sync_at"])
        }
    }

    /// Partially updates the singleton row. Each parameter is a double
    /// optional: the outer `.none` (the default, i.e. omitted) leaves that
    /// column untouched; `.some(x)` — including `.some(nil)` — writes `x`,
    /// same field-omission convention as `ContactRepository.upsert`'s
    /// `lastInteractionAt`.
    public func update(
        userID: String?? = .none,
        serverCursor: String?? = .none,
        lastSyncAt: String?? = .none
    ) throws {
        var assignments: [String] = []
        var arguments: [DatabaseValueConvertible?] = []

        if case .some(let value) = userID {
            assignments.append("user_id = ?")
            arguments.append(value)
        }
        if case .some(let value) = serverCursor {
            assignments.append("server_cursor = ?")
            arguments.append(value)
        }
        if case .some(let value) = lastSyncAt {
            assignments.append("last_sync_at = ?")
            arguments.append(value)
        }
        guard !assignments.isEmpty else { return }

        try database.write { db in
            try db.execute(
                sql: "UPDATE sync_state SET \(assignments.joined(separator: ", ")) WHERE id = 1",
                arguments: StatementArguments(arguments)
            )
        }
    }

    /// Clears every field to NULL — the shape `migrateLocalDataOwnership`
    /// leaves `sync_state` in after reassigning local rows to a new
    /// identity, so the next sync starts a clean cursor negotiation under the
    /// new user rather than resuming an old one.
    public func reset() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE sync_state SET user_id = NULL, server_cursor = NULL, last_sync_at = NULL WHERE id = 1")
        }
    }
}
