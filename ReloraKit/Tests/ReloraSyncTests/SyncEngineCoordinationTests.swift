import Foundation
import GRDB
import Testing
import ReloraCore
import ReloraData
@testable import ReloraSync

/// Collects every value a test observes off `statusUpdates` in the
/// background, since the stream itself has no history — a test that starts
/// iterating after a transition has already happened would otherwise miss it.
private actor StatusRecorder {
    private(set) var statuses: [SyncStatus] = []
    func record(_ status: SyncStatus) { statuses.append(status) }
}

/// Waits for the recorded statuses to satisfy `isSatisfied`, up to a
/// generous ceiling. The retry chain is driven by the real clock, so a
/// fixed sleep either has to pad every run or races a loaded machine —
/// polling the recorder returns as soon as the expected status lands and
/// only spends the full ceiling when it never does.
private func waitForStatuses(
    _ recorder: StatusRecorder,
    timeout: Duration = .seconds(5),
    until isSatisfied: @Sendable ([SyncStatus]) -> Bool
) async -> [SyncStatus] {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        let statuses = await recorder.statuses
        if isSatisfied(statuses) { return statuses }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await recorder.statuses
}

/// A thread-safe mutable flag for `isOnline` closures that need to flip
/// mid-test (`SyncEngine`'s own `isOnline` closure is captured once at
/// init, so the closure itself must be able to change what it returns).
private final class OnlineFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); defer { lock.unlock() }; value = newValue }
}

@Suite struct SyncEngineCoordinationTests {

    // MARK: - Single-flight

    @Test func concurrentSyncNowCallsJoinTheInFlightRunRatherThanStartingASecond() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            try SyncFixtures.insertContact(db, id: "c1", updatedAt: "2026-01-01T00:00:00.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:00.000Z")
        }
        let transport = StubSyncTransport()
        // Slow down the push so both calls are guaranteed to overlap.
        await transport.setOnUpsert { _, _ in
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        let engine = SyncEngine(
            database: database, transport: transport,
            userIDProvider: { testUserID }, isOnline: { true },
            writeDebounceNanoseconds: 0, retryDelaysMilliseconds: []
        )

        async let first = engine.syncNow(reason: "first")
        try await Task.sleep(nanoseconds: 15_000_000) // let the first call claim inFlightTask
        async let second = engine.syncNow(reason: "second")

        let (firstOutcome, secondOutcome) = await (first, second)
        #expect(firstOutcome.kind == .succeeded)
        #expect(secondOutcome.kind == .succeeded)

        // Only one push actually happened -- the second call joined rather
        // than running its own push/pull cycle.
        let callCount = await transport.upsertCallOrder.count
        #expect(callCount == 1)
    }

    // MARK: - Debounce generation

    @Test func debounceCollapsesABurstOfLocalWritesIntoOneSync() async throws {
        let database = try AppDatabase.inMemory()
        let transport = StubSyncTransport()
        let engine = SyncEngine(
            database: database, transport: transport,
            userIDProvider: { testUserID }, isOnline: { true },
            writeDebounceNanoseconds: 50_000_000, retryDelaysMilliseconds: []
        )

        await engine.noteLocalWrite(reason: "a")
        try await Task.sleep(nanoseconds: 15_000_000)
        await engine.noteLocalWrite(reason: "b")
        try await Task.sleep(nanoseconds: 15_000_000)
        await engine.noteLocalWrite(reason: "c")

        // Wait comfortably past the debounce window measured from the last call.
        try await Task.sleep(nanoseconds: 150_000_000)

        // Every sync issues exactly one pull query per table (the stub has no
        // server rows, so each page comes back short immediately); a count
        // that is not a single multiple of the table count would mean the
        // burst fired more than once.
        let pullCount = await transport.pullQueries.count
        #expect(pullCount == SyncTable.allCases.count)
    }

    @Test func aNewerImmediateScheduleSupersedesAPendingRetryWhichNeverFires() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            try SyncFixtures.insertContact(db, id: "c1", updatedAt: "2026-01-01T00:00:00.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:00.000Z")
        }
        let transport = StubSyncTransport()
        await transport.queueUpsertError(table: .contacts, error: BackendError(code: "ERR", message: "boom", httpStatus: 500))
        let engine = SyncEngine(
            database: database, transport: transport,
            userIDProvider: { testUserID }, isOnline: { true },
            writeDebounceNanoseconds: 0, retryDelaysMilliseconds: [400]
        )

        let recorder = StatusRecorder()
        let watcher = Task {
            for await status in engine.statusUpdates {
                await recorder.record(status)
            }
        }

        let first = await engine.syncNow(reason: "initial")
        guard case .failed = first.kind else {
            Issue.record("expected the seeded error to fail the first attempt")
            watcher.cancel()
            return
        }
        // A retry is now pending ~400ms out, sharing the one schedule slot.

        // Supersede it with a fresh immediate schedule -- the error queue is
        // now empty, so this attempt succeeds.
        await engine.scheduleImmediateSync(reason: "supersede")
        try await Task.sleep(nanoseconds: 120_000_000)
        let statusesAfterSupersede = await recorder.statuses
        #expect(statusesAfterSupersede.last == .idle)

        // Wait past where the original (should-be-cancelled) retry would
        // have fired, and confirm nothing further happened.
        try await Task.sleep(nanoseconds: 400_000_000)
        let statusesAfterWaiting = await recorder.statuses
        #expect(statusesAfterWaiting.count == statusesAfterSupersede.count)

        watcher.cancel()
    }

    // MARK: - Offline short-circuit

    @Test func offlineSkipsWithoutTouchingStatusOrTheNetwork() async throws {
        let database = try AppDatabase.inMemory()
        let transport = StubSyncTransport()
        let engine = SyncEngine(
            database: database, transport: transport,
            userIDProvider: { testUserID }, isOnline: { false }
        )

        let outcome = await engine.syncNow(reason: "test")
        #expect(outcome.kind == .skippedOffline)
        #expect(outcome.pulledReminderTombstoneNotificationIDs == [])

        let status = await engine.status
        #expect(status == .idle)

        let pushCount = await transport.upsertCallOrder.count
        let pullCount = await transport.pullQueries.count
        #expect(pushCount == 0)
        #expect(pullCount == 0)
    }

    @Test func offlineIsCheckedBeforeSingleFlightSoItNeverJoinsAStillRunningOnlineAttempt() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            try SyncFixtures.insertContact(db, id: "c1", updatedAt: "2026-01-01T00:00:00.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:00.000Z")
        }
        let transport = StubSyncTransport()
        await transport.setOnUpsert { _, _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let online = OnlineFlag(true)
        let engine = SyncEngine(
            database: database, transport: transport,
            userIDProvider: { testUserID }, isOnline: { online.get() },
            writeDebounceNanoseconds: 0, retryDelaysMilliseconds: []
        )

        async let first = engine.syncNow(reason: "online-run")
        try await Task.sleep(nanoseconds: 15_000_000) // let the online run claim inFlightTask
        online.set(false)
        let second = await engine.syncNow(reason: "offline-check")

        // The offline call returns immediately with .skippedOffline instead
        // of waiting on (and adopting the result of) the in-flight run.
        #expect(second.kind == .skippedOffline)

        online.set(true)
        let firstOutcome = await first
        #expect(firstOutcome.kind == .succeeded)
    }

    // MARK: - Non-account no-op

    @Test func withNoActiveAccountSyncNowSkipsAndNoteLocalWriteAndScheduleImmediateSyncAreNoOps() async throws {
        let database = try AppDatabase.inMemory()
        let transport = StubSyncTransport()
        let engine = SyncEngine(
            database: database, transport: transport,
            userIDProvider: { nil }, isOnline: { true },
            writeDebounceNanoseconds: 20_000_000
        )

        let outcome = await engine.syncNow(reason: "test")
        #expect(outcome.kind == .skippedNoAccount)
        #expect(outcome.pulledReminderTombstoneNotificationIDs == [])

        await engine.noteLocalWrite(reason: "ignored")
        await engine.scheduleImmediateSync(reason: "also-ignored")
        try await Task.sleep(nanoseconds: 100_000_000)

        let pushCount = await transport.upsertCallOrder.count
        let pullCount = await transport.pullQueries.count
        #expect(pushCount == 0)
        #expect(pullCount == 0)

        let status = await engine.status
        #expect(status == .idle)
    }

    // MARK: - Status stream transitions

    @Test func syncingFiresOnEveryAttemptIncludingRetriesAndIdleFiresOnlyOnEventualSuccess() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            try SyncFixtures.insertContact(db, id: "c1", updatedAt: "2026-01-01T00:00:00.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:00.000Z")
        }
        let transport = StubSyncTransport()
        // The first two attempts fail; the third (second retry) finds an
        // empty error queue and succeeds.
        await transport.queueUpsertError(table: .contacts, error: BackendError(code: "ERR1", message: "boom", httpStatus: 500))
        await transport.queueUpsertError(table: .contacts, error: BackendError(code: "ERR2", message: "boom again", httpStatus: 500))
        let engine = SyncEngine(
            database: database, transport: transport,
            userIDProvider: { testUserID }, isOnline: { true },
            writeDebounceNanoseconds: 0, retryDelaysMilliseconds: [10, 10]
        )

        let recorder = StatusRecorder()
        let watcher = Task {
            for await status in engine.statusUpdates {
                await recorder.record(status)
            }
        }

        let first = await engine.syncNow(reason: "attempt-1")
        guard case .failed = first.kind else {
            Issue.record("expected attempt 1 to fail")
            watcher.cancel()
            return
        }

        // Wait for both automatic retries (10ms, then 10ms) to play out.
        let statuses = await waitForStatuses(recorder) { $0.contains(.idle) }
        let syncingCount = statuses.filter { $0 == .syncing }.count
        // Three attempts total: the initial call plus two automatic retries.
        #expect(syncingCount >= 3)
        // Status never went to .failed -- the retries were never exhausted
        // before the sync eventually succeeded.
        #expect(!statuses.contains(.failed))
        #expect(statuses.last == .idle)

        watcher.cancel()
    }

    @Test func failedFiresOnlyOnceRetriesAreExhaustedNeverOnAnIntermediateFailure() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            try SyncFixtures.insertContact(db, id: "c1", updatedAt: "2026-01-01T00:00:00.000Z", isDirty: true, dirtyAt: "2026-01-01T00:00:00.000Z")
        }
        let transport = StubSyncTransport()
        // Every attempt fails: the initial call plus all three retries.
        for _ in 0..<4 {
            await transport.queueUpsertError(table: .contacts, error: BackendError(code: "ERR", message: "boom", httpStatus: 500))
        }
        let engine = SyncEngine(
            database: database, transport: transport,
            userIDProvider: { testUserID }, isOnline: { true },
            writeDebounceNanoseconds: 0, retryDelaysMilliseconds: [10, 10, 10]
        )

        let recorder = StatusRecorder()
        let watcher = Task {
            for await status in engine.statusUpdates {
                await recorder.record(status)
            }
        }

        let first = await engine.syncNow(reason: "attempt-1")
        guard case .failed = first.kind else {
            Issue.record("expected attempt 1 to fail")
            watcher.cancel()
            return
        }

        // Wait for all three automatic retries to play out and exhaust.
        let statuses = await waitForStatuses(recorder) { $0.contains(.failed) }
        #expect(statuses.filter { $0 == .failed }.count == 1)
        #expect(statuses.last == .failed)
        // Every attempt failed -- .idle never appears.
        #expect(!statuses.contains(.idle))

        watcher.cancel()
    }
}
