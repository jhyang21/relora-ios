import Foundation
import ReloraServices

/// The two `IdentityController` collaborators that do nothing, shared by
/// `AppRouterNotificationTapTests` and `AuthViewModelTests`. Both suites build
/// a controller only to drive something else through it, so both want the
/// migration and the guest store out of the way.
///
/// Plain lock-free classes rather than actors: every requirement here returns
/// a constant, and `OwnershipMigrating` mixes synchronous and async members,
/// which an actor cannot satisfy without an `await` at each call.
final class NoOpOwnershipMigration: OwnershipMigrating, @unchecked Sendable {
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

final class NoOpLocalGuestIDStore: LocalGuestIDStore, @unchecked Sendable {
    func read() throws -> String? { nil }
    func write(_ userID: String?) throws {}
}

/// Never succeeds any write path — enough to drive
/// `IdentityController.bootstrap()` through to `isBootstrapped = true` on
/// whichever identity `session` implies. The default `nil` resolves no
/// session at all, which leaves `identity` at `.unresolved`.
struct NoOpAuthBackend: AuthBackend {
    var session: AuthSession?

    func currentSession() async throws -> AuthSession? { session }
    func signInAnonymously() async throws -> AuthSession { throw NoOpError() }
    func signUp(email: String, password: String) async throws -> AuthSession? { throw NoOpError() }
    func signIn(email: String, password: String) async throws -> AuthSession { throw NoOpError() }
    func signInWithApple(idToken: String, nonce: String) async throws -> AuthSession { throw NoOpError() }
    func signOut() async throws {}
    func resetPassword(email: String, redirectTo: URL?) async throws { throw NoOpError() }
    func updatePassword(_ newPassword: String) async throws { throw NoOpError() }
    func sessionFromURL(_ url: URL) async throws -> AuthSession { throw NoOpError() }
}

struct NoOpError: Error, Sendable {}

/// A controller wired to all three do-nothing collaborators, for a suite that
/// needs one to exist rather than to do anything.
@MainActor
func makeNoOpIdentityController() -> IdentityController {
    IdentityController(
        authBackend: NoOpAuthBackend(),
        ownershipMigration: NoOpOwnershipMigration(),
        localGuestIDStore: NoOpLocalGuestIDStore()
    )
}
