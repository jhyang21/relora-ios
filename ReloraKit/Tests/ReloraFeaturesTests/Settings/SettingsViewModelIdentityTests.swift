import Foundation
import Testing
import ReloraCore
import ReloraData
import ReloraDesign
import ReloraServices
import ReloraSync
@testable import ReloraFeatures

/// What Settings shows at the bottom of the screen depends on which of the
/// four identities is in play: an account gets Sign Out and Delete
/// Account, a real anonymous session gets Delete My Data, and a local
/// guest gets neither — it never opened a session, so there is nothing on
/// the server for the delete endpoint to remove.
///
/// The view builds that choice out of `isAccount` and `isAnonymous`, so
/// those two are what this pins.
@Suite struct SettingsViewModelIdentityTests {

    // MARK: - Collaborators

    private struct StubSyncTransport: SyncTransport {
        func upsert(table: SyncTable, rows: [JSONObject], onConflict: String) async throws {}
        func pull(table: SyncTable, userID: String, updatedAfter: String?, range: (from: Int, to: Int)) async throws -> [JSONObject] { [] }
    }

    private struct StubVoiceAccess: VoiceAccessProviding {
        func accessSnapshot(userID: String?) async -> VoiceAccessSnapshot { .freeAndUnused }
    }

    /// Billing is built with a `nil` config, which is the "billing not
    /// configured" path — nothing here touches a purchase.
    private actor StubPurchases: PurchasesProviding {
        func configure(apiKey: String) async {}
        func logIn(appUserID: String) async throws -> PurchasesCustomerInfo { .empty }
        func logOut() async throws {}
        func products(identifiers: [String]) async -> [PurchasesProduct] { [] }
        func customerInfo() async throws -> PurchasesCustomerInfo { .empty }
        func purchase(productID: String) async throws -> PurchasesPurchaseResult { .userCancelled }
        func restorePurchases() async throws -> PurchasesCustomerInfo { .empty }
        func introEligibility(productIDs: [String]) async -> [String: PurchasesIntroEligibility] { [:] }
    }

    @MainActor
    private func makeViewModel(session: AuthSession?) async throws -> SettingsViewModel {
        let database = try AppDatabase.inMemory()
        let identity = IdentityController(
            authBackend: NoOpAuthBackend(session: session),
            ownershipMigration: NoOpOwnershipMigration(),
            localGuestIDStore: NoOpLocalGuestIDStore()
        )
        await identity.bootstrap()

        let engine = SyncEngine(
            database: database,
            transport: StubSyncTransport(),
            userIDProvider: { nil }
        )
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center, database: database)
        let settings = AppSettingsStore(database: database)

        return SettingsViewModel(
            database: database,
            identity: identity,
            sync: SyncOrchestrator(engine: engine, database: database, cancelNotifications: { _ in }),
            billing: BillingService(purchases: StubPurchases(), config: nil),
            voiceAccess: StubVoiceAccess(),
            notifications: NotificationEnvironment(
                scheduler: scheduler,
                reconciler: NotificationReconciler(database: database, scheduler: scheduler, center: center, settings: settings),
                center: center,
                primingStore: ReminderNotificationPrimingStore(database: database)
            ),
            toasts: ReloraToastCenter(),
            router: AppRouter()
        )
    }

    private func anonymousSession() -> AuthSession {
        AuthSession(
            user: AuthUser(id: "anon-1", email: nil, isAnonymous: true),
            accessToken: "access",
            refreshToken: "refresh"
        )
    }

    private func accountSession() -> AuthSession {
        AuthSession(
            user: AuthUser(id: "acct-1", email: "a@example.com", isAnonymous: false),
            accessToken: "access",
            refreshToken: "refresh"
        )
    }

    // MARK: - Tests

    @MainActor
    @Test func anAnonymousSessionIsAnonymousAndNotAnAccount() async throws {
        let viewModel = try await makeViewModel(session: anonymousSession())

        #expect(viewModel.isAnonymous)
        #expect(!viewModel.isAccount)
    }

    /// The two are mutually exclusive, which is what lets the view write
    /// them as one `if / else if` chain.
    @MainActor
    @Test func anAccountIsAnAccountAndNotAnonymous() async throws {
        let viewModel = try await makeViewModel(session: accountSession())

        #expect(viewModel.isAccount)
        #expect(!viewModel.isAnonymous)
    }

    /// No session and no stored guest id leaves the controller unresolved.
    /// Neither row shows: there is no account to sign out of, and no
    /// server-side row for the delete endpoint to remove.
    @MainActor
    @Test func anUnresolvedIdentityShowsNeitherRow() async throws {
        let viewModel = try await makeViewModel(session: nil)

        #expect(!viewModel.isAccount)
        #expect(!viewModel.isAnonymous)
    }
}
