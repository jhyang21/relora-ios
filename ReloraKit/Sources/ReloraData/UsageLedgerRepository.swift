import Foundation
import GRDB
import ReloraCore

/// Append-only local ledger for `voice_note_usage_events`, ported from the
/// local-cache half of apps/mobile/src/features/billing/storage.ts
/// (`persistLocalUsageEvent`/`getLocalUsageSummary`). The monthly/lifetime
/// window calculation itself (`getCurrentMonthWindow`, which uses the
/// device's local calendar, not UTC) is a billing-policy concern built on top
/// of this repository's primitives, not a fact about the table — it belongs
/// in ReloraServices/ReloraFeatures alongside the RevenueCat-vs-local-ledger
/// branching that surrounds it in storage.ts. `count(userID:from:to:)` below
/// is what that layer calls twice (once unbounded, once with a month's
/// `[start, end)`) to reproduce `UsageSummary`.
public struct UsageLedgerRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Appends a usage event. `INSERT OR IGNORE` matches
    /// `persistLocalUsageEvent`: the id is the idempotency key, so a retried
    /// call with the same id is a silent no-op rather than a duplicate row or
    /// an error.
    @discardableResult
    public func append(
        id: String = ReloraID.new(),
        userID: String,
        processedAt: String,
        source: String
    ) throws -> String {
        try database.write { db in
            try Self.write(db, id: id, userID: userID, processedAt: processedAt, source: source)
        }
        return id
    }

    /// The row write on its own, against an already-open connection. See
    /// `MemoryRepository.write` for why this split exists — for a usage event
    /// it is what keeps the ledger honest: a guest's quota is only spent if
    /// the note it paid for actually landed.
    static func write(
        _ db: Database,
        id: String,
        userID: String,
        processedAt: String,
        source: String
    ) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO voice_note_usage_events (id, user_id, processed_at, source, server_synced_at)
                VALUES (?, ?, ?, ?, NULL)
                """,
            arguments: [id, userID, processedAt, source]
        )
    }

    /// All usage events for a user, most recently processed first.
    public func list(userID: String) throws -> [UsageEvent] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, user_id, processed_at, source, server_synced_at
                    FROM voice_note_usage_events WHERE user_id = ? ORDER BY processed_at DESC
                    """,
                arguments: [userID]
            )
            return rows.map(Self.mapUsageEvent)
        }
    }

    /// Usage events not yet pushed to the server ledger (`server_synced_at IS
    /// NULL`), oldest first — the natural push order.
    public func listUnsynced(userID: String) throws -> [UsageEvent] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, user_id, processed_at, source, server_synced_at
                    FROM voice_note_usage_events
                    WHERE user_id = ? AND server_synced_at IS NULL
                    ORDER BY processed_at ASC
                    """,
                arguments: [userID]
            )
            return rows.map(Self.mapUsageEvent)
        }
    }

    /// Counts events for a user, optionally bounded to a half-open
    /// `[from, to)` window on `processed_at` — the primitive
    /// `getLocalUsageSummary` in storage.ts calls twice: once unbounded for
    /// `totalProcessedNotes`, once with a calendar-month window for
    /// `processedNotesThisMonth`.
    public func count(userID: String, from: String? = nil, to: String? = nil) throws -> Int {
        try database.read { db in
            var sql = "SELECT COUNT(*) FROM voice_note_usage_events WHERE user_id = ?"
            var arguments: [DatabaseValueConvertible?] = [userID]
            if let from {
                sql += " AND processed_at >= ?"
                arguments.append(from)
            }
            if let to {
                sql += " AND processed_at < ?"
                arguments.append(to)
            }
            return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) ?? 0
        }
    }

    /// Marks events as pushed to the server ledger, setting `server_synced_at`
    /// on every id in `ids`. No direct TS analogue exists yet (the RN client
    /// only ever clears this column back to NULL, during identity migration),
    /// but the column exists for exactly this and the port spec asks for the
    /// write path explicitly.
    public func markServerSynced(ids: [String], syncedAt: String = ReloraTimestamp.now()) throws {
        guard !ids.isEmpty else { return }
        try database.write { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            var arguments: [DatabaseValueConvertible?] = [syncedAt]
            arguments.append(contentsOf: ids.map { $0 as DatabaseValueConvertible? })
            try db.execute(
                sql: "UPDATE voice_note_usage_events SET server_synced_at = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments(arguments)
            )
        }
    }

    private static func mapUsageEvent(_ row: Row) -> UsageEvent {
        UsageEvent(
            id: row["id"],
            userID: row["user_id"],
            processedAt: row["processed_at"],
            source: row["source"],
            serverSyncedAt: row["server_synced_at"]
        )
    }
}
