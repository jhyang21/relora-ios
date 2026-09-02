import Foundation
import GRDB
import ReloraCore

/// The identity states relevant to ownership of local rows. Mirrors RN's
/// `IdentityKind` (apps/mobile/src/features/billing/types.ts), which is a
/// bare `'none' | 'anonymous' | 'account'` union — kept here as ReloraData's
/// own copy rather than importing ReloraServices' richer `Identity` type,
/// since ReloraServices depends on ReloraData and not the other way around.
/// `ReloraServices.Identity` carries a fourth, ReloraKit-only case
/// (`localGuest`, distinguishing a Supabase-anonymous session from a
/// same-device-only guest with no session at all — RN flattens both into
/// `'anonymous'`); its `identityKind` bridges to this type by mapping
/// `localGuest` to `.anonymous`, preserving RN's ownership rules exactly.
public enum IdentityKind: String, Sendable, Equatable {
    case none
    case anonymous
    case account
}

/// `succeeded` — rows now belong to the account. `deferred` — the attempt
/// failed; the marker survives and the next hydration retries. `skipped` —
/// nothing to do (no marker, no target account, or same user). Mirrors
/// `OwnershipMigrationOutcome` in ownershipMigration.ts.
public enum MigrationOutcome: Equatable, Sendable {
    case succeeded
    case deferred
    case skipped
}

/// Durable guest → account ownership migration, ported from
/// apps/mobile/src/state/ownershipMigration.ts (marker + retry orchestration)
/// and apps/mobile/src/state/localOwnership.ts (the actual row rewrite).
///
/// The rewrite (`migrateOwnership`) can fail — locked database, interrupted
/// process. When it does, the user's local rows are still owned by the guest
/// id and would otherwise be orphaned with no signal and no retry path. This
/// type records a pending marker in `app_settings` before every attempt and
/// only clears it once the reassignment succeeds, so a caller
/// (`IdentityController`, in ReloraServices) can retry on the next session
/// hydration until it completes.
public struct GuestMigration: Sendable {
    private let database: AppDatabase
    private let settings: AppSettingsStore

    /// Mirrors `OWNERSHIP_MIGRATION_RETRY_DELAYS_MS` in ownershipMigration.ts.
    public static let retryDelays: [Duration] = [.milliseconds(1000), .milliseconds(3000), .milliseconds(8000)]

    public init(database: AppDatabase) {
        self.database = database
        self.settings = AppSettingsStore(database: database)
    }

    // MARK: - Pending marker

    /// Marker persisted while a guest → account reassignment is still
    /// incomplete. Mirrors `PendingOwnershipMigration` in
    /// ownershipMigration.ts; `CodingKeys` match its JSON field names
    /// exactly (this marker is native-only local state — RN never reads
    /// it — but matching spellings keeps the on-disk JSON legible against
    /// the RN source it was ported from).
    public struct PendingMigration: Equatable, Sendable, Codable {
        public var fromUserID: String
        /// Account the rows were last being moved to. Re-targeted if the
        /// user signs into another account.
        public var toUserID: String
        /// How many hydrations have tried and failed so far.
        public var failedAttempts: Int
        public var lastAttemptAt: String
        public var lastError: String?

        public init(fromUserID: String, toUserID: String, failedAttempts: Int = 0, lastAttemptAt: String, lastError: String? = nil) {
            self.fromUserID = fromUserID
            self.toUserID = toUserID
            self.failedAttempts = failedAttempts
            self.lastAttemptAt = lastAttemptAt
            self.lastError = lastError
        }

        enum CodingKeys: String, CodingKey {
            case fromUserID = "fromUserId"
            case toUserID = "toUserId"
            case failedAttempts
            case lastAttemptAt
            case lastError
        }
    }

    /// Reads the pending migration marker, treating unreadable or
    /// unparseable rows as absent — mirrors `readPendingOwnershipMigration`.
    public func readPending() throws -> PendingMigration? {
        guard let raw = try settings.getRawValue(.pendingOwnershipMigration), let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(PendingMigration.self, from: data)
    }

    /// Writes or clears the pending migration marker.
    public func writePending(_ value: PendingMigration?) throws {
        guard let value else {
            try settings.setRawValue(.pendingOwnershipMigration, nil)
            return
        }
        let data = try JSONEncoder().encode(value)
        try settings.setRawValue(.pendingOwnershipMigration, String(decoding: data, as: UTF8.self))
    }

    /// True when local rows are still stranded under a guest id. Drives the
    /// retry banner. Mirrors `hasPendingOwnershipMigration`.
    public func hasPending() throws -> Bool {
        try readPending() != nil
    }

    // MARK: - Row rewrite

    /// Whether `identityKind` may claim rows stranded by a failed migration.
    ///
    /// Only a real account can. A signed-out or anonymous identity must
    /// never pull the rows onto itself: the marker records that the user
    /// was moving *to* an account, and retargeting them at a throwaway
    /// guest id would strand them further. This gates the automatic
    /// resume, the manual retry, and whether the failure is surfaced at
    /// all — one rule, so no caller can skip it. Mirrors
    /// `canClaimStrandedRows`.
    public static func canClaimStrandedRows(_ identityKind: IdentityKind) -> Bool {
        identityKind == .account
    }

    /// Reassigns local rows from `fromUserID` to `toUserID`, ported from
    /// `migrateLocalDataOwnership` in localOwnership.ts. Idempotent and
    /// safe to resume after a partial failure: every UPDATE is scoped
    /// `WHERE user_id = fromUserID`, so a row already reassigned by an
    /// earlier attempt simply falls out of the WHERE clause on retry
    /// rather than erroring or double-writing.
    ///
    /// The four content tables are marked dirty so the sync engine
    /// replicates the new ownership; `voice_note_usage_events` is
    /// re-owned with `server_synced_at` cleared (matching RN, though no
    /// upload path reads that column — the rows only feed the local
    /// fallback count; see docs/milestone-notes.md, "Usage ledger");
    /// `sync_state` is fully reset so the
    /// next sync starts a clean cursor negotiation under the new
    /// identity rather than resuming an old one.
    ///
    /// Runs the rewrite in one transaction with `PRAGMA foreign_keys =
    /// OFF` for its duration. SQLite refuses to change that pragma while
    /// a transaction is open (it is a documented no-op there), so the
    /// pragma toggle happens outside GRDB's automatic transaction wrapper
    /// via `AppDatabase.writeWithoutTransaction`, with the actual rewrite
    /// wrapped in its own explicit `Database.inTransaction`. FK
    /// enforcement is restored in a `defer` so a thrown error still
    /// leaves the connection with foreign keys back on.
    public func migrateOwnership(fromUserID: String, toUserID: String) throws {
        guard !fromUserID.isEmpty, !toUserID.isEmpty, fromUserID != toUserID else {
            return
        }
        let now = ReloraTimestamp.now()

        try database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            defer {
                // Best-effort restore: if this fails the connection is in a
                // bad enough state that the thrown rewrite error (if any)
                // is the one worth surfacing, not this.
                try? db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            try db.inTransaction {
                for table in ["contacts", "key_things", "memories", "reminders"] {
                    try db.execute(
                        sql: """
                            UPDATE \(table)
                            SET user_id = ?, updated_at = ?, is_dirty = 1, dirty_at = ?
                            WHERE user_id = ?
                            """,
                        arguments: [toUserID, now, now, fromUserID]
                    )
                }
                try db.execute(
                    sql: """
                        UPDATE voice_note_usage_events
                        SET user_id = ?, server_synced_at = NULL
                        WHERE user_id = ?
                        """,
                    arguments: [toUserID, fromUserID]
                )
                try db.execute(
                    sql: "UPDATE sync_state SET user_id = NULL, server_cursor = NULL, last_sync_at = NULL WHERE id = 1"
                )
                return .commit
            }
        }
    }

    // MARK: - Retry orchestration

    /// Reassigns local rows with retries, keeping a durable marker until it
    /// succeeds. Never throws — a failed migration must not abort session
    /// hydration. Mirrors `runOwnershipMigration`.
    @discardableResult
    public func runMigration(
        fromUserID: String,
        toUserID: String,
        source: String,
        delays: [Duration] = GuestMigration.retryDelays,
        now: @Sendable () -> Date = { Date() }
    ) async -> MigrationOutcome {
        guard !fromUserID.isEmpty, !toUserID.isEmpty, fromUserID != toUserID else {
            return .skipped
        }

        let existing = try? readPending()
        let failedAttemptsSoFar = (existing?.fromUserID == fromUserID) ? (existing?.failedAttempts ?? 0) : 0

        // Record intent before touching the database so an interrupted
        // process still leaves a marker.
        try? writePending(PendingMigration(
            fromUserID: fromUserID,
            toUserID: toUserID,
            failedAttempts: failedAttemptsSoFar,
            lastAttemptAt: ReloraTimestamp.from(now()),
            lastError: existing?.lastError
        ))

        var lastError: Error?
        let totalAttempts = 1 + delays.count
        for attempt in 0..<totalAttempts {
            do {
                try migrateOwnership(fromUserID: fromUserID, toUserID: toUserID)
                try? writePending(nil)
                return .succeeded
            } catch {
                lastError = error
                if attempt < delays.count {
                    try? await Task.sleep(for: delays[attempt])
                }
            }
        }

        try? writePending(PendingMigration(
            fromUserID: fromUserID,
            toUserID: toUserID,
            failedAttempts: failedAttemptsSoFar + 1,
            lastAttemptAt: ReloraTimestamp.from(now()),
            lastError: lastError.map { String(describing: $0) }
        ))
        return .deferred
    }

    /// Retries a migration left incomplete by an earlier session. Re-targets
    /// the stored marker at the currently active identity so signing into a
    /// different account still rescues the rows. `toUserID: nil`, or an
    /// `identityKind` that is not `.account`, leaves the marker untouched —
    /// see `canClaimStrandedRows`. Mirrors `resumePendingOwnershipMigration`.
    public func resumePendingMigrationIfAny(
        toUserID: String?,
        identityKind: IdentityKind,
        source: String
    ) async -> (outcome: MigrationOutcome, fromUserID: String?, toUserID: String?) {
        guard let pending = try? readPending() else {
            return (.skipped, nil, nil)
        }
        guard let toUserID, Self.canClaimStrandedRows(identityKind) else {
            // Signed out, or anonymous. Nothing may claim the rows yet —
            // keep the marker for the next signed-in session rather than
            // retargeting it at a guest id.
            return (.skipped, pending.fromUserID, nil)
        }
        if pending.fromUserID == toUserID {
            // The rows already belong to the active account; the marker is stale.
            try? writePending(nil)
            return (.skipped, pending.fromUserID, toUserID)
        }

        let outcome = await runMigration(fromUserID: pending.fromUserID, toUserID: toUserID, source: source)
        return (outcome, pending.fromUserID, toUserID)
    }

    // MARK: - Clearing local data

    /// Deletes every local content and usage row, resets `sync_state` to
    /// unowned, and flags the search index for a rebuild. Ports
    /// `clearLocalData` in dataControls.ts. Not really "migration" —
    /// grouped here anyway (rather than a second new ReloraData file)
    /// because both are bulk lifecycle operations over the same
    /// identity-owned rows, and `IdentityController.deleteAccount()`
    /// (ReloraServices) needs exactly one ReloraData-shaped seam to call
    /// through rather than two. Callers are expected to have already
    /// cancelled any scheduled local notifications first — RN's
    /// `cancelAllScheduledNotificationsAsync()` is the first line of the
    /// function this ports, and that call has no equivalent at this layer.
    public func clearAllLocalData() throws {
        try database.write { db in
            for table in ["reminders", "memories", "key_things", "contacts", "voice_note_usage_events", "app_settings", "contact_search"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            try db.execute(sql: "UPDATE sync_state SET user_id = NULL, server_cursor = NULL, last_sync_at = NULL WHERE id = 1")
            try db.execute(
                sql: """
                    INSERT INTO search_index_meta (key, value) VALUES ('contact_search_needs_rebuild', '1')
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """
            )
        }
    }
}
