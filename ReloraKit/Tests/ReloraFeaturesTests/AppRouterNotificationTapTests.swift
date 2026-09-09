import Foundation
import Testing
import ReloraServices
@testable import ReloraFeatures

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
        let identity = makeNoOpIdentityController()
        #expect(!identity.isBootstrapped)

        await router.handleNotificationTap(contactTapURL, identity: identity)

        #expect(router.pendingDeepLinkURL == contactTapURL)
        #expect(router.path.isEmpty)
    }

    @Test("A tap arriving after bootstrap navigates immediately, with nothing queued")
    func navigatesImmediatelyOnceBootstrapped() async {
        let router = AppRouter()
        let identity = makeNoOpIdentityController()
        await identity.bootstrap()
        #expect(identity.isBootstrapped)

        await router.handleNotificationTap(contactTapURL, identity: identity)

        #expect(router.path == [.contactDetail(contactID: "abc-123")])
        #expect(router.pendingDeepLinkURL == nil)
    }

    @Test("replayPendingDeepLink is a no-op when nothing was queued")
    func replayNoOpWhenEmpty() async {
        let router = AppRouter()
        let identity = makeNoOpIdentityController()
        await identity.bootstrap()

        let result = await router.replayPendingDeepLink(identity: identity)

        #expect(result == nil)
        #expect(router.path.isEmpty)
    }

    @Test("replayPendingDeepLink leaves a queued URL alone until identity has actually bootstrapped")
    func replayWaitsForBootstrap() async {
        let router = AppRouter()
        let identity = makeNoOpIdentityController()
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
        let identity = makeNoOpIdentityController()
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
