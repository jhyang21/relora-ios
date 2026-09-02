import Foundation
import GRDB
import ReloraCore
import ReloraData

/// User-visible sync lifecycle states, ported verbatim from `SyncStatus` in
/// apps/mobile/src/state/appStateCoordinator.ts.
public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case failed
}

/// A push or pull table failure, distinguishing an auth failure from every
/// other backend error so a caller can react (e.g. re-prompt sign-in)
/// without string-matching `BackendError.code` itself. `.other` covers a
/// thrown error with no `BackendError` shape (defensive — every real
/// failure path in this engine throws `BackendError`); it carries only a
/// description because arbitrary `Error` existentials are not `Sendable`.
public enum SyncFailure: Error, Sendable, Equatable {
    case authRequired(BackendError)
    case backend(BackendError)
    case other(String)

    static func from(_ error: Error) -> SyncFailure {
        if let backendError = error as? BackendError {
            return backendError.code == BackendError.authRequired
                ? .authRequired(backendError)
                : .backend(backendError)
        }
        return .other(String(describing: error))
    }
}

/// The result of one `syncNow` call. `.skippedNoAccount`/`.skippedOffline`
/// never touch `status` or run any network call, mirroring `runSync`'s early
/// returns in appStateCoordinator.ts. `pulledReminderTombstoneNotificationIDs`
/// is only ever non-empty on `.succeeded` — this engine never touches
/// `UNUserNotificationCenter` itself; the caller owns cancelling these ids
/// (see `SyncEngine.syncNow`'s doc).
public struct SyncOutcome: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case skippedNoAccount
        case skippedOffline
        case succeeded
        case failed(SyncFailure)
    }

    public var kind: Kind
    public var pulledReminderTombstoneNotificationIDs: [String]

    public static func skippedNoAccount() -> SyncOutcome {
        SyncOutcome(kind: .skippedNoAccount, pulledReminderTombstoneNotificationIDs: [])
    }

    public static func skippedOffline() -> SyncOutcome {
        SyncOutcome(kind: .skippedOffline, pulledReminderTombstoneNotificationIDs: [])
    }
}

/// The offline-first push/pull sync engine, ported from
/// apps/mobile/src/sync/syncEngine.ts (the push/pull mechanics) and
/// apps/mobile/src/state/appStateCoordinator.ts (debounce, retry,
/// single-flight, offline short-circuit, status). An actor because every
/// mutable field below — the in-flight task, the retry attempt counter, the
/// debounce generation, `status` — is accessed from whatever isolation
/// domain calls `noteLocalWrite()`/`syncNow(reason:)`, same as the RN
/// coordinator's closures being invoked from arbitrary call sites across the
/// app.
///
/// Runs only for account identity: every entry point consults
/// `userIDProvider`, and a `nil` result is a no-op, exactly as
/// `createSyncCoordinator`'s `getUserId` gate. There is no separate
/// "identity changed" API — a caller notices the active user changed and
/// calls `scheduleImmediateSync(reason:)` (the `queueSync('auth-ready',
/// true)` call `handleActiveUserStateChange` makes) or `reset()` (the
/// `migrateLocalDataOwnership` reset shape) itself.
public actor SyncEngine {
    // MARK: - Constants (defaults match syncEngine.ts / appStateCoordinator.ts)

    public static let defaultPushBatchSize = 500
    public static let defaultMaxPushBatches = 20
    public static let defaultPullPageSize = 500
    public static let defaultWriteDebounceMilliseconds = 2_000
    public static let defaultRetryDelaysMilliseconds = [2_000, 5_000, 15_000]
    /// Mirrors `NOTIFICATION_CLEANUP_CHUNK_SIZE` in syncEngine.ts — kept well
    /// under SQLite's default 999 bound-parameter limit for the `IN (...)`
    /// query `collectPulledReminderTombstoneNotificationIDs` runs.
    public static let notificationCleanupChunkSize = 200

    private let database: AppDatabase
    private let syncStateStore: SyncStateStore
    private let transport: SyncTransport
    private let userIDProvider: @Sendable () -> String?
    private let isOnline: @Sendable () -> Bool

    private let pushBatchSize: Int
    private let maxPushBatches: Int
    private let pullPageSize: Int
    private let writeDebounceNanoseconds: UInt64
    private let retryDelaysMilliseconds: [Int]

    private var inFlightTask: Task<SyncOutcome, Never>?
    private var retryAttempt = 0
    private var scheduleGeneration = 0
    private var pendingScheduleTask: Task<Void, Never>?

    public private(set) var status: SyncStatus = .idle
    private let statusContinuation: AsyncStream<SyncStatus>.Continuation
    /// Every `status` transition, for UI observation. Mirrors
    /// `onSyncStatusChange` in appStateCoordinator.ts. `nonisolated` so a
    /// caller can start iterating it without an `await` hop; the stream
    /// itself is a value type wrapping a thread-safe continuation.
    public nonisolated let statusUpdates: AsyncStream<SyncStatus>

    public init(
        database: AppDatabase,
        transport: SyncTransport,
        userIDProvider: @escaping @Sendable () -> String?,
        isOnline: @escaping @Sendable () -> Bool = { true },
        pushBatchSize: Int = SyncEngine.defaultPushBatchSize,
        maxPushBatches: Int = SyncEngine.defaultMaxPushBatches,
        pullPageSize: Int = SyncEngine.defaultPullPageSize,
        writeDebounceNanoseconds: UInt64 = UInt64(SyncEngine.defaultWriteDebounceMilliseconds) * 1_000_000,
        retryDelaysMilliseconds: [Int] = SyncEngine.defaultRetryDelaysMilliseconds
    ) {
        self.database = database
        self.syncStateStore = SyncStateStore(database: database)
        self.transport = transport
        self.userIDProvider = userIDProvider
        self.isOnline = isOnline
        self.pushBatchSize = pushBatchSize
        self.maxPushBatches = maxPushBatches
        self.pullPageSize = pullPageSize
        self.writeDebounceNanoseconds = writeDebounceNanoseconds
        self.retryDelaysMilliseconds = retryDelaysMilliseconds
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        self.statusUpdates = stream
        self.statusContinuation = continuation
    }

    // MARK: - Public entry points

    /// Debounced schedule for a local write, mirroring `queueSync(reason,
    /// false)` — every call restarts the same debounce window (via a shared
    /// generation counter with `scheduleImmediateSync`/retry scheduling), so
    /// a burst of local writes collapses into one sync `writeDebounceNanoseconds`
    /// after the last one. A no-op while there is no active account.
    public func noteLocalWrite(reason: String = "local-write") {
        guard userIDProvider() != nil else { return }
        scheduleSync(reason: reason, delayNanoseconds: writeDebounceNanoseconds)
    }

    /// Immediate (zero-delay) schedule, mirroring `queueSync(reason, true)` —
    /// e.g. the `'auth-ready'` call `handleActiveUserStateChange` makes when
    /// the active user changes. Still goes through the same one-tick
    /// scheduling path as the debounced case (not a direct `syncNow` call),
    /// so it is still cancellable by a subsequent schedule and still
    /// coalesces with one already pending.
    public func scheduleImmediateSync(reason: String) {
        guard userIDProvider() != nil else { return }
        scheduleSync(reason: reason, delayNanoseconds: 0)
    }

    /// Runs (or joins) one sync attempt for the current account, mirroring
    /// `requestSyncNow` / the body of `runSync` in appStateCoordinator.ts.
    ///
    /// Check order matches RN exactly: no account -> `.skippedNoAccount`
    /// (no status change); offline -> `.skippedOffline` (no status change,
    /// checked *before* single-flight — an offline call never joins a
    /// still-running online attempt, it simply no-ops); otherwise, a
    /// concurrent call already in flight is joined rather than starting a
    /// second run.
    ///
    /// On success, `pulledReminderTombstoneNotificationIDs` carries the
    /// local `notification_id`s of reminders whose tombstones this pull
    /// applied. This engine never calls `UNUserNotificationCenter` itself
    /// (it lives in ReloraData/ReloraSync, which know nothing about
    /// notifications) — the caller must cancel each id and, once
    /// cancelled, is free to clear `reminders.notification_id` for that row
    /// itself.
    @discardableResult
    public func syncNow(reason: String) async -> SyncOutcome {
        guard let userID = userIDProvider() else { return .skippedNoAccount() }
        guard isOnline() else { return .skippedOffline() }

        if let existing = inFlightTask {
            return await existing.value
        }

        let task = Task { await self.runAttempt(userID: userID, reason: reason) }
        inFlightTask = task
        return await task.value
    }

    /// Runs one attempt and drops the in-flight marker before returning,
    /// mirroring `runSync`'s `finally { syncInFlight = null }` — the marker
    /// is cleared by the attempt itself, not by whoever awaits it. Clearing
    /// it in `syncNow` after `await task.value` instead would leave it set
    /// across the resumption hop, and a retry (or any other scheduled sync)
    /// firing inside that window would join this already-finished attempt
    /// and adopt its stale outcome instead of starting the next one.
    private func runAttempt(userID: String, reason: String) async -> SyncOutcome {
        let outcome = await performSync(userID: userID, reason: reason)
        inFlightTask = nil
        return outcome
    }

    /// Cancels any pending debounced/retry schedule and clears retry/in-flight
    /// bookkeeping, mirroring `reset()` in appStateCoordinator.ts exactly:
    /// an already-running `syncNow` task is *not* cancelled (RN's `reset()`
    /// only drops the reference to the in-flight promise, it never aborts
    /// it), and `status` is left untouched (RN's `reset()` never calls
    /// `onSyncStatusChange`).
    public func reset() {
        pendingScheduleTask?.cancel()
        pendingScheduleTask = nil
        scheduleGeneration += 1
        retryAttempt = 0
        inFlightTask = nil
    }

    // MARK: - Scheduling (debounce + retry share one cancellable slot,
    // mirroring appStateCoordinator.ts's single `syncTimer` variable used by
    // both `queueSync` and the retry `scheduleTimer` call)

    private func scheduleSync(reason: String, delayNanoseconds: UInt64) {
        pendingScheduleTask?.cancel()
        scheduleGeneration += 1
        let generation = scheduleGeneration
        pendingScheduleTask = Task {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self.fireScheduledSync(generation: generation, reason: reason)
        }
    }

    private func fireScheduledSync(generation: Int, reason: String) async {
        // A newer schedule (or `reset()`) superseded this one; do nothing.
        guard generation == scheduleGeneration else { return }
        _ = await syncNow(reason: reason)
    }

    // MARK: - The sync attempt itself

    private func performSync(userID: String, reason: String) async -> SyncOutcome {
        setStatus(.syncing)
        do {
            try await pushAll(userID: userID)
            let tombstoneIDs = try await pullAll(userID: userID)
            retryAttempt = 0
            setStatus(.idle)
            return SyncOutcome(kind: .succeeded, pulledReminderTombstoneNotificationIDs: tombstoneIDs)
        } catch {
            let failure = SyncFailure.from(error)
            if !scheduleRetryIfPossible() {
                // All retry delays exhausted — mirrors the RN comment: "the
                // sync has permanently failed until the user retries."
                // `retryAttempt` is deliberately left at its exhausted value
                // (never reset here) so every subsequent call fails the same
                // `retryAttempt < count` guard and re-lands here, exactly as
                // RN's `syncRetryAttempt` is only ever reset on success.
                setStatus(.failed)
            }
            return SyncOutcome(kind: .failed(failure), pulledReminderTombstoneNotificationIDs: [])
        }
    }

    /// Schedules the next retry through the shared `scheduleSync` slot (so a
    /// local write arriving during the backoff window supersedes it, just as
    /// a new `queueSync` call replaces RN's pending `syncTimer`). Returns
    /// whether a retry was scheduled; `false` means the backoff list is
    /// exhausted. Status is deliberately left as `.syncing` here on a
    /// non-terminal failure — RN's `catch` block only calls
    /// `onSyncStatusChange('failed')` in the exhausted branch, never between
    /// retries.
    private func scheduleRetryIfPossible() -> Bool {
        guard retryAttempt < retryDelaysMilliseconds.count else { return false }
        let delayMs = retryDelaysMilliseconds[retryAttempt]
        retryAttempt += 1
        scheduleSync(reason: "retry", delayNanoseconds: UInt64(delayMs) * 1_000_000)
        return true
    }

    private func setStatus(_ newStatus: SyncStatus) {
        status = newStatus
        statusContinuation.yield(newStatus)
    }

    // MARK: - Push

    private struct DirtyRow {
        var id: String
        var dirtyAt: String?
        var json: JSONObject
    }

    private func pushAll(userID: String) async throws {
        for table in SyncTable.allCases {
            try await pushDirtyTable(table: table, userID: userID)
        }
    }

    /// Ported from `pushDirtyTable` in syncEngine.ts, including the
    /// `MAX_PUSH_BATCHES` safety valve: if the guarded flag-clearing keeps
    /// missing (rows re-dirtied faster than they push), this stops after
    /// `maxPushBatches` iterations without throwing — the remaining dirty
    /// rows simply sync on the next cycle.
    private func pushDirtyTable(table: SyncTable, userID: String) async throws {
        for _ in 0..<maxPushBatches {
            let dirtyRows = try readDirtyRows(table: table, userID: userID, limit: pushBatchSize)
            if dirtyRows.isEmpty { return }

            let payload = dirtyRows.map { RowTransforms.rowForPush(table: table, localRow: $0.json) }
            try await transport.upsert(table: table, rows: payload, onConflict: "id")

            try clearDirtyFlags(table: table, rows: dirtyRows)

            if dirtyRows.count < pushBatchSize { return }
        }
    }

    private func readDirtyRows(table: SyncTable, userID: String, limit: Int) throws -> [DirtyRow] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM \(table.rawValue)
                    WHERE user_id = ? AND is_dirty = 1
                    ORDER BY dirty_at ASC, updated_at ASC
                    LIMIT \(limit)
                    """,
                arguments: [userID]
            )
            return rows.map { row in
                DirtyRow(id: row["id"], dirtyAt: row["dirty_at"], json: row.asJSONObject())
            }
        }
    }

    /// Clears `is_dirty`/`dirty_at` only for rows still matching the exact
    /// `dirty_at` snapshot that was just pushed — a row edited again after
    /// being read for this batch (but before this clear runs) keeps its new
    /// `is_dirty = 1` and gets picked up by the next push, ported verbatim
    /// from the guarded `UPDATE ... WHERE id = ? AND is_dirty = 1 AND
    /// dirty_at = ?` in `pushDirtyTable`. A row with a NULL `dirty_at` is
    /// skipped entirely (`if (!row.dirty_at) continue`) — that state should
    /// not occur (every dirty write sets `dirty_at`), but ported as-is
    /// rather than tightened.
    private func clearDirtyFlags(table: SyncTable, rows: [DirtyRow]) throws {
        try database.write { db in
            for row in rows {
                guard let dirtyAt = row.dirtyAt else { continue }
                try db.execute(
                    sql: """
                        UPDATE \(table.rawValue)
                        SET is_dirty = 0, dirty_at = NULL
                        WHERE id = ? AND is_dirty = 1 AND dirty_at = ?
                        """,
                    arguments: [row.id, dirtyAt]
                )
            }
        }
    }

    // MARK: - Pull

    private struct PulledTable {
        var table: SyncTable
        var rows: [JSONObject]
        var maxUpdatedAt: String?
    }

    /// Ported from `syncAll`'s pull phase: fetch every table from the server
    /// into memory first, compute the next cursor from the global max
    /// `updated_at` seen, then write every pulled row *and* advance the
    /// cursor in one local transaction. Returns the local `notification_id`s
    /// of any pulled reminder tombstones for the caller to cancel.
    private func pullAll(userID: String) async throws -> [String] {
        let nowISO = ReloraTimestamp.now()
        let syncState = try syncStateStore.read()
        let storedCursor = syncState.userID == userID ? syncState.serverCursor : nil
        let cursor = Self.sanitizeCursorForPull(storedCursor, nowISO: nowISO)

        var pulledTables: [PulledTable] = []
        for table in SyncTable.allCases {
            pulledTables.append(try await fetchTableSince(table: table, userID: userID, cursor: cursor))
        }

        // Compared as instants for the same reason `fetchTableSince` does:
        // the per-table maxima reaching here can carry different timestamptz
        // shapes, and string order between shapes is not chronological.
        var maxPulledUpdatedAt: String?
        for pulled in pulledTables {
            guard let candidate = pulled.maxUpdatedAt else { continue }
            guard let current = maxPulledUpdatedAt else {
                maxPulledUpdatedAt = candidate
                continue
            }
            if Self.isLaterInstant(candidate, than: current) {
                maxPulledUpdatedAt = candidate
            }
        }
        let nextCursor = Self.pickNextCursor(cursor: cursor, maxPulledUpdatedAt: maxPulledUpdatedAt, nowISO: nowISO)

        // Single local transaction for every pulled row across every table
        // plus the cursor advance — a crash between the last row write and
        // the cursor update cannot lose the cursor: it stays where it was
        // and the next sync safely re-pulls the same (idempotent) rows.
        try database.write { db in
            for pulled in pulledTables {
                for row in pulled.rows {
                    try Self.applyPulledRow(db, table: pulled.table, serverRow: row)
                }
            }
            if pulledTables.contains(where: { !$0.rows.isEmpty }) {
                try ContactSearchIndex.markNeedsRebuild(db)
            }
            try db.execute(
                sql: "UPDATE sync_state SET user_id = ?, server_cursor = ?, last_sync_at = ? WHERE id = 1",
                arguments: [userID, nextCursor, nowISO]
            )
        }

        return try collectPulledReminderTombstoneNotificationIDs(pulledTables: pulledTables)
    }

    /// Drains every page for `table` updated after `cursor`. Pagination is a
    /// correctness requirement, not hygiene, per syncEngine.ts's own
    /// comment: PostgREST silently caps unpaged responses, and the cursor is
    /// a global max across tables — a truncated table would let the cursor
    /// advance past rows that were never pulled, skipping them forever.
    private func fetchTableSince(table: SyncTable, userID: String, cursor: String?) async throws -> PulledTable {
        var rows: [JSONObject] = []
        var from = 0
        while true {
            let page = try await transport.pull(
                table: table,
                userID: userID,
                updatedAfter: cursor,
                range: (from: from, to: from + pullPageSize - 1)
            )
            rows.append(contentsOf: page)
            if page.count < pullPageSize { break }
            from += pullPageSize
        }

        guard !rows.isEmpty else { return PulledTable(table: table, rows: [], maxUpdatedAt: nil) }

        // Compared as instants, not as Strings. PostgREST does not echo one
        // consistent timestamptz shape: a row this client last wrote comes
        // back as `...602Z`, a row the server touched as `...60222+00:00`,
        // and lexicographically the first sorts above the second even though
        // it is the earlier instant. A string max therefore hands
        // `pickNextCursor` a cursor that sits before rows already pulled,
        // which the next `gt.` filter skips for good.
        //
        // The winning row's raw server string is kept verbatim: re-emitting
        // it through `Date` would truncate sub-millisecond digits and move
        // the `gt.` boundary backwards.
        var maxUpdatedAt: String?
        for row in rows {
            guard case .string(let updatedAt)? = row["updated_at"] else { continue }
            guard let current = maxUpdatedAt else {
                maxUpdatedAt = updatedAt
                continue
            }
            if Self.isLaterInstant(updatedAt, than: current) {
                maxUpdatedAt = updatedAt
            }
        }
        return PulledTable(table: table, rows: rows, maxUpdatedAt: maxUpdatedAt)
    }

    /// Whether `candidate` is a later instant than `current`. Falls back to
    /// string order when either value fails to parse — the same order the
    /// rest of this engine uses, and the only order left when there is no
    /// instant to compare.
    private static func isLaterInstant(_ candidate: String, than current: String) -> Bool {
        guard let candidateMs = FlexibleTimestamp.epochMilliseconds(candidate),
              let currentMs = FlexibleTimestamp.epochMilliseconds(current) else {
            return candidate > current
        }
        return candidateMs > currentMs
    }

    /// Applies one pulled server row locally. Builds the column list from
    /// the row's own (transformed) keys rather than a fixed per-table list —
    /// this is what makes the pull upsert leave local-only columns alone:
    /// see `RowTransforms.localOnlyColumns`'s doc.
    ///
    /// The `WHERE {table}.is_dirty = 0` guard on the `DO UPDATE` mirrors the
    /// push-side `dirty_at` guard: a row the user edited locally after this
    /// pull snapshot was fetched must not be silently overwritten with
    /// (older, from this device's perspective) server values or marked
    /// clean — the locally-dirty row wins until its own push echoes it back.
    private static func applyPulledRow(_ db: Database, table: SyncTable, serverRow: JSONObject) throws {
        let localRow = RowTransforms.localColumns(table: table, serverRow: serverRow)
        guard localRow["id"] != nil else { return }

        let keys = localRow.keys.sorted()
        let placeholders = keys.map { _ in "?" }.joined(separator: ", ")
        let updateAssignments = keys
            .filter { $0 != "id" }
            .map { "\($0) = excluded.\($0)" }
            + ["is_dirty = 0", "dirty_at = NULL"]
        let values: [DatabaseValueConvertible?] = keys.map { localRow[$0]!.asSQLiteBindValue() }

        try db.execute(
            sql: """
                INSERT INTO \(table.rawValue) (\(keys.joined(separator: ", ")), is_dirty, dirty_at)
                VALUES (\(placeholders), 0, NULL)
                ON CONFLICT(id) DO UPDATE SET \(updateAssignments.joined(separator: ", "))
                WHERE \(table.rawValue).is_dirty = 0
                """,
            arguments: StatementArguments(values)
        )
    }

    /// Re-reads the *local* `reminders` table (not the pulled server rows)
    /// for tombstones, chunked to stay under SQLite's bound-parameter limit.
    /// Reading back locally after the write — rather than trusting the
    /// pulled rows directly — is what makes a tombstone skipped by the
    /// dirty-row guard (a local edit racing the pull) correctly keep its
    /// notification: if the guard left `deleted_at` NULL locally, this query
    /// will not find that row, exactly matching
    /// `cancelNotificationsForPulledReminderTombstones`'s own comment.
    private func collectPulledReminderTombstoneNotificationIDs(pulledTables: [PulledTable]) throws -> [String] {
        guard let remindersPulled = pulledTables.first(where: { $0.table == .reminders }) else { return [] }
        let tombstoneIDs: [String] = remindersPulled.rows.compactMap { row in
            guard case .string(let id)? = row["id"] else { return nil }
            guard let deletedAt = row["deleted_at"], deletedAt != .null else { return nil }
            return id
        }
        guard !tombstoneIDs.isEmpty else { return [] }

        var notificationIDs: [String] = []
        var start = 0
        while start < tombstoneIDs.count {
            let end = min(start + Self.notificationCleanupChunkSize, tombstoneIDs.count)
            let chunk = Array(tombstoneIDs[start..<end])
            let chunkIDs: [String] = try database.read { db in
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                let arguments: [DatabaseValueConvertible?] = chunk.map { $0 as DatabaseValueConvertible? }
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT notification_id FROM reminders
                        WHERE id IN (\(placeholders)) AND deleted_at IS NOT NULL AND notification_id IS NOT NULL
                        """,
                    arguments: StatementArguments(arguments)
                )
                return rows.map { $0["notification_id"] }
            }
            notificationIDs.append(contentsOf: chunkIDs)
            start = end
        }
        return notificationIDs
    }

    // MARK: - Cursor arithmetic (pure, ported from syncEngine.ts)

    /// Mirrors `sanitizeCursorForPull`: a stored cursor from the future
    /// (device clock skew) is discarded rather than trusted, since trusting
    /// it would silently skip every row updated between now and that
    /// bogus future timestamp.
    static func sanitizeCursorForPull(_ cursor: String?, nowISO: String) -> String? {
        guard let cursor, let cursorMs = FlexibleTimestamp.epochMilliseconds(cursor) else { return nil }
        let nowMs = FlexibleTimestamp.epochMilliseconds(nowISO) ?? cursorMs
        return cursorMs > nowMs ? nil : cursor
    }

    /// Mirrors `pickNextCursor` exactly, including its own clock-skew guard:
    /// a pulled `updated_at` that reads later than local "now" is capped to
    /// `nowISO` rather than adopted verbatim, so a skewed server/device
    /// clock cannot advance the cursor further than this device believes
    /// "now" to be.
    static func pickNextCursor(cursor: String?, maxPulledUpdatedAt: String?, nowISO: String) -> String? {
        guard let maxPulledUpdatedAt, let pulledMs = FlexibleTimestamp.epochMilliseconds(maxPulledUpdatedAt) else {
            return cursor
        }
        let nowMs = FlexibleTimestamp.epochMilliseconds(nowISO) ?? pulledMs
        let cappedPulledAt = pulledMs > nowMs ? nowISO : maxPulledUpdatedAt

        guard let cursor, let cursorMs = FlexibleTimestamp.epochMilliseconds(cursor) else {
            return cappedPulledAt
        }
        return (pulledMs > nowMs || pulledMs > cursorMs) ? cappedPulledAt : cursor
    }
}

/// A permissive ISO-8601 epoch-milliseconds parser, standing in for
/// JavaScript's lenient `Date.parse` (which syncEngine.ts's `toEpochMs` uses
/// directly). This engine's *own* cursor/`dirty_at` values always match
/// `ReloraTimestamp`'s strict millisecond-`Z` wire format, but a pulled
/// `updated_at` is a Postgres `timestamptz` echoed through PostgREST, which
/// does not necessarily match that exact shape (a `+00:00` offset instead of
/// a literal `Z`, or a different fractional-second digit count) — `Date.parse`
/// shrugs that off; `ReloraTimestamp.parse`'s fixed `DateFormatter` does not.
/// Tried in order from strictest (fastest, and correct for this engine's own
/// values) to most permissive.
enum FlexibleTimestamp {
    static func epochMilliseconds(_ string: String) -> Double? {
        if let date = ReloraTimestamp.parse(string) {
            return date.timeIntervalSince1970 * 1_000
        }
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: string) {
            return date.timeIntervalSince1970 * 1_000
        }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        if let date = wholeSeconds.date(from: string) {
            return date.timeIntervalSince1970 * 1_000
        }
        return nil
    }
}
