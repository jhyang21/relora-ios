import Foundation
import ReloraCore
import ReloraData
import ReloraDesign
import ReloraFeatures
import ReloraServices
import ReloraSync
// The one file in the app target allowed to import this — see
// `NotificationCenterProviding.swift`'s doc comment. Needed here only to
// hand `UNUserNotificationCenter.current().delegate` the notification-tap
// delegate; everything else about scheduling goes through the protocol.
import UserNotifications

/// The app's composition root: the one place that knows how the pieces fit.
///
/// Every object below is built here and injected downward. No screen constructs
/// a database, a backend, or a sync engine — that is what makes the whole of
/// ReloraKit testable with fakes, and it is why this file is the only one in the
/// app target with more than a few lines in it.
@MainActor
final class AppBootstrap {
    let database: AppDatabase
    let identity: IdentityController
    let sync: SyncOrchestrator
    let router: AppRouter
    let toasts = ReloraToastCenter()
    let voice: VoiceCaptureEnvironment
    let notifications: NotificationEnvironment
    let billing: BillingService

    /// Kept alive for the process: `UNUserNotificationCenter.delegate` is a
    /// weak reference, and nothing else on this object holds one.
    private let notificationDelegate: NotificationDelegate

    /// False when no Supabase credentials are configured for this build. The app
    /// still runs — local-first means the database, not the server, is the
    /// product — but no account can be created, so nothing ever syncs.
    let isBackendConfigured: Bool

    private let network: NetworkMonitor
    private let syncIdentity: SyncIdentityBox
    private var hasStarted = false

    init() throws {
        // Locals first, then assignment. A stored property cannot be captured by
        // a closure until `self` is fully initialized, and the sync engine needs
        // to capture the monitor and the identity box at construction.
        let database = try AppDatabase.onDisk()
        let network = NetworkMonitor()
        let syncIdentity = SyncIdentityBox()

        let configured = BackendConfigLoader.fromBundle()
        let config = configured ?? BackendConfigLoader.unconfigured
        let authBackend: any AuthBackend = configured == nil
            ? UnconfiguredAuthBackend()
            : SupabaseAuthBackend(config: config)

        let identity = IdentityController(
            authBackend: authBackend,
            ownershipMigration: OwnershipMigrationAdapter(GuestMigration(database: database)),
            localGuestIDStore: AppSettingsGuestIDStore(database: database)
        )

        let engine = SyncEngine(
            database: database,
            transport: PostgRESTSyncTransport(
                client: PostgRESTLite(config: config, tokenProvider: identity)
            ),
            // Both closures read a snapshot rather than the live controller: the
            // engine is an actor and asks for these synchronously, and the
            // controller lives on the main actor.
            userIDProvider: { syncIdentity.syncUserID },
            isOnline: { network.isOnline }
        )

        // The voice stack, built once. `RecordingController` owns the engine
        // and `AudioSessionController` owns the category and the interruption
        // notifications — one of each for the process, because two recorders
        // fighting over the audio session is a bug that only shows up on a
        // phone call.
        //
        // The realtime pipeline wrapping the batch one as its fallback leg —
        // the M7 swap behind the `VoiceTranscriptionPipeline` seam. One
        // shared `EdgeFunctionsClient`: the realtime leg mints sessions and
        // extracts through it, and the batch leg transcribes through it.
        let recorder = RecordingController(sessionController: AudioSessionController())
        let edgeFunctionsClient = EdgeFunctionsClient(config: config, tokenProvider: identity)
        let pipeline = RealtimeVoiceTranscriptionPipeline(
            client: edgeFunctionsClient,
            batch: BatchVoiceTranscriptionPipeline(client: edgeFunctionsClient)
        )

        // The notification stack. One real `UNUserNotificationCenter` for the
        // process — the scheduler, the reconciler, and (in `start()`) sync's
        // cancel closure all wrap this one instance rather than each opening
        // their own.
        let notificationCenter = SystemNotificationCenter()
        let notificationScheduler = NotificationScheduler(center: notificationCenter, database: database)
        let notificationReconciler = NotificationReconciler(
            database: database,
            scheduler: notificationScheduler,
            center: notificationCenter,
            settings: AppSettingsStore(database: database)
        )
        let notifications = NotificationEnvironment(
            scheduler: notificationScheduler,
            reconciler: notificationReconciler,
            center: notificationCenter,
            primingStore: ReminderNotificationPrimingStore(database: database)
        )

        // The billing stack. `BillingConfigLoader` mirrors
        // `BackendConfigLoader`: a build with placeholder RevenueCat keys
        // runs with billing disabled, not broken.
        let billing = BillingService(
            purchases: RevenueCatPurchasesAdapter(),
            config: BillingConfigLoader.fromBundle()
        )

        // Locals, not `self.` reads: the tap closure below must capture the
        // router and delegate before `self` is fully initialized, and Swift
        // forbids any use of `self` (a bare stored-property reference
        // included — it is an implicit self capture) until every stored
        // property is assigned.
        let router = AppRouter()
        let notificationDelegate = NotificationDelegate(onTap: { url in
            Task { @MainActor in
                await router.handleNotificationTap(url, identity: identity)
            }
        })

        self.database = database
        self.network = network
        self.syncIdentity = syncIdentity
        self.identity = identity
        self.router = router
        self.notificationDelegate = notificationDelegate
        self.notifications = notifications
        self.billing = billing
        self.isBackendConfigured = configured != nil
        self.voice = VoiceCaptureEnvironment(
            database: database,
            identity: identity,
            recorder: recorder,
            pipeline: pipeline,
            // The M9 conformer behind the composer's quota gate: plan from
            // the RevenueCat entitlement snapshot, usage counts server-first
            // with the local ledger as fallback.
            access: RevenueCatVoiceAccess(
                billing: billing,
                usageQuery: PostgRESTUsageQuery(config: config, tokenProvider: identity),
                database: database
            ),
            // The monitor, not the orchestrator: the composer asks whether the
            // network is up, which is not the same question as whether a sync
            // is currently allowed to run.
            isOnline: { network.isOnline }
        )
        self.sync = SyncOrchestrator(
            engine: engine,
            database: database,
            isOnline: network.isOnline,
            // The real call the M5 no-op was left for. `SyncOrchestrator.sync`
            // clears `notification_id` locally only after this returns — see
            // docs/milestone-notes.md, "Sync / notifications boundary".
            cancelNotifications: { [notificationScheduler] ids in await notificationScheduler.cancel(ids) }
        )

        // Neither hook had ever been wired anywhere (confirmed by grep before
        // writing this) despite both being documented on `IdentityController`
        // as notification-cancellation hooks.
        //
        // M10: `onSignedOut` also clears the signing-out user's stale
        // `notification_id` values, mirroring RN's `disableReminderNotifications`
        // (cancel-all *and* clear the column), not just the cancel-all half.
        // Local reminder rows deliberately survive sign-out — they reattach on
        // the next sign-in to the same account — but every notification this
        // pass just cancelled would otherwise still be recorded as scheduled on
        // its row, and `NotificationReconciler.rescheduleAll`'s loop only
        // schedules a row whose `notificationID` is nil. Left uncleared, those
        // rows would never be rescheduled again after a sign-in, silently and
        // permanently. `identity.identity` still holds the pre-sign-out value
        // here — `IdentityController.signOut()` runs `onSignedOut` before
        // `hydrate(session: nil...)` nils it out. `[weak identity]` avoids a
        // retain cycle (identity → this closure → identity); low stakes, since
        // `IdentityController` lives for the process either way. A real gap
        // adjacent to, but beyond the letter of, this milestone's assignment —
        // flagged in the M10 report for team-lead to accept or revert.
        identity.onSignedOut = { [notificationCenter, database, weak identity] in
            await notificationCenter.removeAllPending()
            guard let userID = await identity?.identity.ownerUserID else { return }
            let repository = ReminderRepository(database: database)
            let ids = (try? repository.listFullByUser(userID: userID))?.compactMap(\.notificationID) ?? []
            try? repository.clearNotificationIDs(ids)
        }
        identity.onClearingLocalData = { [notificationCenter] in await notificationCenter.removeAllPending() }

        // M10: `deleteRemoteAccountData` was declared on `IdentityController`
        // ("Wire to `EdgeFunctionsClient.deleteAccountData`") but never set —
        // confirmed by grep before writing this. Without it, Settings' delete-
        // account flow would hit `DeleteAccountError.noRemoteDeleteConfigured`
        // on every attempt. `deleteAccount()` already sequences this closure,
        // `onClearingLocalData`, `GuestMigration.clearAllLocalData()`, and
        // `signOut()` in RN's exact order — this one line is the only wiring
        // Settings' delete-account action needs.
        identity.deleteRemoteAccountData = { [edgeFunctionsClient] in
            try await edgeFunctionsClient.deleteAccountData()
        }

        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    /// Runs once, at first launch of the scene.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        // Ports RN's startup `initializeSearchIndex` call: runs any FTS
        // rebuild a previous run's sync pull deferred, so the first search
        // of the session does not pay for it. Best-effort, like RN's.
        try? ContactSearchIndex.initialize(database)

        sync.start()
        sync.observeIdentity(identity, syncUserID: syncIdentity)
        // `sync.observeIdentity` just set `identity.onIdentityApplied` to its
        // own handler. Wrapped rather than overwritten, so a real identity
        // transition (launch restore, sign-in, an anonymous upgrade) both
        // keeps sync's behavior and runs a reconciliation pass — the safety
        // net for anything a missed schedule attempt left behind. Guarded
        // against `.unresolved`: `onIdentityApplied` fires for a sign-out
        // that leaves no stored guest too, and `Identity.ownerUserID`
        // precondition-fails on that case.
        if let syncOnIdentityApplied = identity.onIdentityApplied {
            let notifications = self.notifications
            let billing = self.billing
            identity.onIdentityApplied = { applied in
                await syncOnIdentityApplied(applied)
                // Fire-and-forget, like RN's own billing effect: RevenueCat's
                // configure/logIn/customerInfo round-trips must not delay
                // sign-in completing or the reconciliation pass below.
                Task { await billing.handleIdentityChange(applied) }
                guard case .unresolved = applied else {
                    await notifications.reconciler.rescheduleAll(userID: applied.ownerUserID, trigger: .identityApplied)
                    return
                }
            }
        }

        network.start { [weak self] isOnline in
            Task { @MainActor in self?.sync.setOnline(isOnline) }
        }

        await identity.bootstrap()
        // `onIdentityApplied` covers every later transition, but not a bootstrap
        // that restores an existing session, so the first value is seeded here.
        // Billing needs the same seed for the same reason — without it a
        // restored account session would sit on the free snapshot all
        // process. Fire-and-forget so launch never waits on RevenueCat.
        syncIdentity.update(from: identity.identity)
        Task { [billing, identity] in await billing.handleIdentityChange(identity.identity) }
        sync.setOnline(network.isOnline)
        sync.requestSync(reason: "launch")
        // A notification tapped before bootstrap finished is queued in
        // `router.pendingDeepLinkURL`; identity is settled now, so replay it.
        await router.replayPendingDeepLink(identity: identity)
    }

    /// The app came back to the foreground.
    func enterForeground() {
        sync.requestSync(reason: "foreground")
    }
}

// MARK: - Backend configuration

/// Reads Supabase credentials from the bundle.
///
/// The values arrive through `Config/Secrets.xcconfig` → `Info.plist`, so they
/// are build settings rather than anything checked in. A build with no secrets
/// is a valid build: it runs against the local database alone.
enum BackendConfigLoader {
    /// Stands in when nothing is configured. Never reached by a request — with
    /// `UnconfiguredAuthBackend` there is no session, so `syncUserID` stays nil
    /// and `SyncEngine` skips every run before it builds a URL.
    static let unconfigured = BackendConfig(
        supabaseURL: URL(string: "https://unconfigured.invalid")!,
        anonKey: ""
    )

    static func fromBundle() -> BackendConfig? {
        guard
            let rawURL = string(for: "SupabaseURL"),
            let anonKey = string(for: "SupabaseAnonKey"),
            let url = URL(string: rawURL),
            url.scheme == "https"
        else {
            return nil
        }
        return BackendConfig(supabaseURL: url, anonKey: anonKey)
    }

    /// Treats the placeholder from `Secrets.example.xcconfig` as absent. A
    /// developer who copied the example and has not filled it in should get the
    /// offline app, not a backend that answers every call with 401.
    private static func string(for key: String) -> String? {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "replace-me" else { return nil }
        return trimmed
    }
}

/// The auth backend for a build with no credentials.
///
/// Reports "no session" rather than failing, so the app boots into its
/// signed-out state instead of an error. Anything that would need the server
/// throws, and says why.
struct UnconfiguredAuthBackend: AuthBackend {
    private var unavailable: BackendError {
        BackendError(
            code: "BACKEND_NOT_CONFIGURED",
            message: "This build has no Supabase credentials. Accounts and sync are unavailable.",
            httpStatus: 0
        )
    }

    func currentSession() async throws -> AuthSession? { nil }
    func signInAnonymously() async throws -> AuthSession { throw unavailable }
    func signUp(email: String, password: String) async throws -> AuthSession? { throw unavailable }
    func signIn(email: String, password: String) async throws -> AuthSession { throw unavailable }
    func signOut() async throws {}
    func resetPassword(email: String, redirectTo: URL?) async throws { throw unavailable }
    func updatePassword(_ newPassword: String) async throws { throw unavailable }
    func sessionFromURL(_ url: URL) async throws -> AuthSession { throw unavailable }
}
