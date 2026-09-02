import Foundation
import Testing
import ReloraServices
@testable import ReloraFeatures

// MARK: - Minimal IdentityController fakes

/// Never resolves a session and never succeeds any write path — enough to
/// drive `IdentityController.bootstrap()` through to `isBootstrapped = true`
/// with `identity` left at `.unresolved`, which is all these tests need.
private struct NoOpAuthBackend: AuthBackend {
    func currentSession() async throws -> AuthSession? { nil }
    func signInAnonymously() async throws -> AuthSession { throw NoOpError() }
    func signUp(email: String, password: String) async throws -> AuthSession? { throw NoOpError() }
    func signIn(email: String, password: String) async throws -> AuthSession { throw NoOpError() }
    func signOut() async throws {}
    func resetPassword(email: String, redirectTo: URL?) async throws { throw NoOpError() }
    func updatePassword(_ newPassword: String) async throws { throw NoOpError() }
    func sessionFromURL(_ url: URL) async throws -> AuthSession { throw NoOpError() }
}

private struct NoOpError: Error, Sendable {}

private final class NoOpOwnershipMigration: OwnershipMigrating, @unchecked Sendable {
    func hasPending() throws -> Bool { false }
    func runMigration(fromUserID: String, toUserID: String, source: String) async -> OwnershipMigrationOutcome { .skipped }
    func resumePendingMigrationIfAny(
        currentIdentity: Identity,
        source: String
    ) async -> (outcome: OwnershipMigrationOutcome, fromUserID: String?, toUserID: String?) {
        (.skipped, nil, nil)
    }
    func clearAllLocalData() throws {}
}

private final class NoOpLocalGuestIDStore: LocalGuestIDStore, @unchecked Sendable {
    func read() throws -> String? { nil }
    func write(_ userID: String?) throws {}
}

@MainActor
private func makeIdentity() -> IdentityController {
    IdentityController(
        authBackend: NoOpAuthBackend(),
        ownershipMigration: NoOpOwnershipMigration(),
        localGuestIDStore: NoOpLocalGuestIDStore()
    )
}

private let contactTapURL = URL(string: "relora://contact/abc-123")!

// MARK: - Tests

/// The queued-replay path for a notification tapped before the app can
/// navigate yet — ported from RN's `notificationLinking.ts`. See
/// `AppRouter.handleNotificationTap`/`replayPendingDeepLink`.
@MainActor
@Suite("AppRouter notification-tap deep links")
struct AppRouterNotificationTapTests {
    @Test("A tap arriving before bootstrap finishes is queued, not acted on")
    func queuesBeforeBootstrap() async {
        let router = AppRouter()
        let identity = makeIdentity()
        #expect(!identity.isBootstrapped)

        await router.handleNotificationTap(contactTapURL, identity: identity)

        #expect(router.pendingDeepLinkURL == contactTapURL)
        #expect(router.path.isEmpty)
    }

    @Test("A tap arriving after bootstrap navigates immediately, with nothing queued")
    func navigatesImmediatelyOnceBootstrapped() async {
        let router = AppRouter()
        let identity = makeIdentity()
        await identity.bootstrap()
        #expect(identity.isBootstrapped)

        await router.handleNotificationTap(contactTapURL, identity: identity)

        #expect(router.path == [.contactDetail(contactID: "abc-123")])
        #expect(router.pendingDeepLinkURL == nil)
    }

    @Test("replayPendingDeepLink is a no-op when nothing was queued")
    func replayNoOpWhenEmpty() async {
        let router = AppRouter()
        let identity = makeIdentity()
        await identity.bootstrap()

        let result = await router.replayPendingDeepLink(identity: identity)

        #expect(result == nil)
        #expect(router.path.isEmpty)
    }

    @Test("replayPendingDeepLink leaves a queued URL alone until identity has actually bootstrapped")
    func replayWaitsForBootstrap() async {
        let router = AppRouter()
        let identity = makeIdentity()
        await router.handleNotificationTap(contactTapURL, identity: identity)
        #expect(router.pendingDeepLinkURL == contactTapURL)

        let result = await router.replayPendingDeepLink(identity: identity)

        #expect(result == nil)
        #expect(router.pendingDeepLinkURL == contactTapURL)
        #expect(router.path.isEmpty)
    }

    @Test("replayPendingDeepLink drains and navigates once bootstrap catches up, and a second call is a no-op")
    func replayDrainsOnceAndThenNoOps() async {
        let router = AppRouter()
        let identity = makeIdentity()
        await router.handleNotificationTap(contactTapURL, identity: identity)

        await identity.bootstrap()
        let firstResult = await router.replayPendingDeepLink(identity: identity)

        #expect(firstResult == .contact(id: "abc-123"))
        #expect(router.path == [.contactDetail(contactID: "abc-123")])
        #expect(router.pendingDeepLinkURL == nil)

        let secondResult = await router.replayPendingDeepLink(identity: identity)
        #expect(secondResult == nil)
        #expect(router.path == [.contactDetail(contactID: "abc-123")])
    }
}
