import Foundation
import Observation
import ReloraData
import ReloraServices
import ReloraSync

/// Decides *when* the sync engine runs, and finishes the one job the engine
/// deliberately leaves undone.
///
/// `SyncEngine` knows how to sync; it does not know that an app came back to the
/// foreground, that a user pulled a list down, or that an identity just arrived.
/// This is where those three become sync calls. It is also the observable the
/// UI reads for the sync-failed banner.
///
/// ## The two-step that must not be reordered
///
/// A pull that tombstones a reminder hands back the `notification_id` that
/// reminder still holds. Two things then have to happen **in this order**:
///
/// 1. Cancel the OS notification.
/// 2. Clear `notification_id` locally.
///
/// Step 2 without step 1 leaves a scheduled notification with no row behind it —
/// it fires, and it is about something the user already deleted. That ordering
/// is a binding ruling in `docs/milestone-notes.md`, which is why
/// `cancelNotifications` is a required constructor argument rather than an
/// optional property: a no-op has to be passed on purpose (M8 replaces it with
/// the real `UNUserNotificationCenter` call), never forgotten into existence.
@MainActor
@Observable
public final class SyncOrchestrator {
    public private(set) var status: SyncStatus = .idle
    public private(set) var isOnline: Bool

    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private let reminders: ReminderRepository
    @ObservationIgnored private let cancelNotifications: @Sendable ([String]) async -> Void
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    public init(
        engine: SyncEngine,
        database: AppDatabase,
        isOnline: Bool = true,
        cancelNotifications: @escaping @Sendable ([String]) async -> Void
    ) {
        self.engine = engine
        self.reminders = ReminderRepository(database: database)
        self.isOnline = isOnline
        self.cancelNotifications = cancelNotifications
    }

    /// Begins mirroring the engine's status into observable state.
    public func start() {
        guard statusTask == nil else { return }
        let updates = engine.statusUpdates
        statusTask = Task { [weak self] in
            for await next in updates {
                self?.status = next
            }
        }
    }

    public func stop() {
        statusTask?.cancel()
        statusTask = nil
    }

    public func setOnline(_ value: Bool) {
        guard isOnline != value else { return }
        isOnline = value
        // Coming back from offline is the moment a sync is most likely to
        // succeed and most likely to be wanted.
        if value {
            requestSync(reason: "network-restored")
        }
    }

    /// Fire-and-forget. For the callers that have nothing to wait for: an
    /// identity being applied, the app returning to the foreground.
    public func requestSync(reason: String) {
        Task { await sync(reason: reason) }
    }

    /// Awaits a full sync. This is what `.refreshable` calls, so the spinner
    /// stays until there is genuinely nothing left to wait for.
    ///
    /// Never throws. A failed sync is reported through `status` and the banner
    /// it drives, matching RN's `runPullToRefresh`, which always reloads local
    /// data and leaves the banner as the one error surface — a pull-to-refresh
    /// that throws an alert at someone is a gesture punished for being used.
    public func sync(reason: String) async {
        let outcome = await engine.syncNow(reason: reason)

        let notificationIDs = outcome.pulledReminderTombstoneNotificationIDs
        guard !notificationIDs.isEmpty else { return }

        await cancelNotifications(notificationIDs)
        try? reminders.clearNotificationIDs(notificationIDs)
    }

    /// Wires this orchestrator to an identity controller, so a session arriving
    /// (launch restore, sign-in, anonymous upgrade) starts a sync.
    ///
    /// Sync only runs for a real account — the engine skips everything else —
    /// so this fires on every identity and lets the engine decide.
    ///
    /// The box is updated *before* the sync, not after: the engine reads its
    /// user id at the start of the run, and a sync kicked off by an identity
    /// arriving must not still be looking at the identity before it.
    public func observeIdentity(_ controller: IdentityController, syncUserID: SyncIdentityBox) {
        controller.onIdentityApplied = { [weak self] identity in
            syncUserID.update(from: identity)
            await self?.sync(reason: "identity-applied")
        }
    }
}
