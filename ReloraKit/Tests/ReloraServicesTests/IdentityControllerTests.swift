import Foundation
import Testing
@testable import ReloraServices

private struct FakeAuthError: Error, Sendable, Equatable {}

private func accountSession(userID: String = "acct-1", email: String? = "person@example.com") -> AuthSession {
    AuthSession(user: AuthUser(id: userID, email: email, isAnonymous: false), accessToken: "access-\(userID)", refreshToken: "refresh-\(userID)")
}

private func anonymousSession(userID: String = "anon-1") -> AuthSession {
    AuthSession(user: AuthUser(id: userID, email: nil, isAnonymous: true), accessToken: "access-\(userID)", refreshToken: "refresh-\(userID)")
}

// MARK: - FakeAuthBackend

private actor FakeAuthBackend: AuthBackend {
    enum SignInAnonymouslyBehavior {
        case succeed(AuthSession)
        case fail(Error)
        /// Never returns — exercises `IdentityController`'s own timeout
        /// race rather than a fast failure.
        case hang
    }

    private var _currentSession: AuthSession?
    private var signInAnonymouslyBehavior: SignInAnonymouslyBehavior
    private var signUpResult: Result<AuthSession?, Error>
    private var signInResult: Result<AuthSession, Error>
    private var sessionFromURLResult: Result<AuthSession, Error>

    private(set) var signInAnonymouslyCallCount = 0
    private(set) var signOutCallCount = 0
    private(set) var resetPasswordCalls: [(email: String, redirectTo: URL?)] = []
    private(set) var updatePasswordCalls: [String] = []

    init(
        currentSession: AuthSession? = nil,
        signInAnonymously: SignInAnonymouslyBehavior = .fail(FakeAuthError()),
        signUpResult: Result<AuthSession?, Error> = .failure(FakeAuthError()),
        signInResult: Result<AuthSession, Error> = .failure(FakeAuthError()),
        sessionFromURLResult: Result<AuthSession, Error> = .failure(FakeAuthError())
    ) {
        self._currentSession = currentSession
        self.signInAnonymouslyBehavior = signInAnonymously
        self.signUpResult = signUpResult
        self.signInResult = signInResult
        self.sessionFromURLResult = sessionFromURLResult
    }

    func setSignInResult(_ result: Result<AuthSession, Error>) { signInResult = result }

    func currentSession() async throws -> AuthSession? { _currentSession }

    func signInAnonymously() async throws -> AuthSession {
        signInAnonymouslyCallCount += 1
        switch signInAnonymouslyBehavior {
        case .succeed(let session):
            return session
        case .fail(let error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            throw FakeAuthError()
        }
    }

    func signUp(email: String, password: String) async throws -> AuthSession? { try signUpResult.get() }
    func signIn(email: String, password: String) async throws -> AuthSession { try signInResult.get() }
    func signOut() async throws { signOutCallCount += 1 }
    func resetPassword(email: String, redirectTo: URL?) async throws { resetPasswordCalls.append((email, redirectTo)) }
    func updatePassword(_ newPassword: String) async throws { updatePasswordCalls.append(newPassword) }
    func sessionFromURL(_ url: URL) async throws -> AuthSession { try sessionFromURLResult.get() }
}

// MARK: - FakeOwnershipMigration

/// A plain, lock-guarded class rather than an actor: `OwnershipMigrating`
/// mixes synchronous (`hasPending`, `clearAllLocalData`) and async
/// (`runMigration`, `resumePendingMigrationIfAny`) requirements, and an
/// actor's own methods would need `nonisolated` to witness the
/// synchronous ones — which can't touch actor-isolated call-log storage
/// without `await`. A manual lock sidesteps that; matches
/// `MockURLProtocol`'s convention in EdgeFunctionsTests.swift.
private final class FakeOwnershipMigration: OwnershipMigrating, @unchecked Sendable {
    private let lock = NSLock()
    private var _hasPending: Bool
    private var _runMigrationOutcome: OwnershipMigrationOutcome
    private var _resumeOutcome: (outcome: OwnershipMigrationOutcome, fromUserID: String?, toUserID: String?)
    private var _runMigrationCalls: [(fromUserID: String, toUserID: String, source: String)] = []
    private var _resumeCalls: [(currentIdentity: Identity, source: String)] = []
    private var _clearAllLocalDataCallCount = 0

    init(
        hasPending: Bool = false,
        runMigrationOutcome: OwnershipMigrationOutcome = .succeeded,
        resumeOutcome: (outcome: OwnershipMigrationOutcome, fromUserID: String?, toUserID: String?) = (.skipped, nil, nil)
    ) {
        self._hasPending = hasPending
        self._runMigrationOutcome = runMigrationOutcome
        self._resumeOutcome = resumeOutcome
    }

    var runMigrationCalls: [(fromUserID: String, toUserID: String, source: String)] { lock.withLock { _runMigrationCalls } }
    var resumeCalls: [(currentIdentity: Identity, source: String)] { lock.withLock { _resumeCalls } }
    var clearAllLocalDataCallCount: Int { lock.withLock { _clearAllLocalDataCallCount } }

    func hasPending() throws -> Bool { lock.withLock { _hasPending } }

    func runMigration(fromUserID: String, toUserID: String, source: String) async -> OwnershipMigrationOutcome {
        lock.withLock { _runMigrationCalls.append((fromUserID, toUserID, source)) }
        return lock.withLock { _runMigrationOutcome }
    }

    func resumePendingMigrationIfAny(currentIdentity: Identity, source: String) async -> (outcome: OwnershipMigrationOutcome, fromUserID: String?, toUserID: String?) {
        lock.withLock { _resumeCalls.append((currentIdentity, source)) }
        return lock.withLock { _resumeOutcome }
    }

    func clearAllLocalData() throws {
        lock.withLock { _clearAllLocalDataCallCount += 1 }
    }
}

// MARK: - FakeLocalGuestIDStore

private final class FakeLocalGuestIDStore: LocalGuestIDStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(stored: String? = nil) {
        self.stored = stored
    }

    func read() throws -> String? { lock.withLock { stored } }
    func write(_ userID: String?) throws { lock.withLock { stored = userID } }
}

// MARK: - Call log (for cross-hook ordering)

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    var events: [String] { lock.withLock { _events } }
    func record(_ event: String) { lock.withLock { _events.append(event) } }
}

// MARK: - Fixture

private func makeController(
    authBackend: FakeAuthBackend = FakeAuthBackend(),
    ownershipMigration: FakeOwnershipMigration = FakeOwnershipMigration(),
    guestID: String? = nil,
    timeout: Duration = .milliseconds(30)
) -> (controller: IdentityController, authBackend: FakeAuthBackend, ownershipMigration: FakeOwnershipMigration, guestStore: FakeLocalGuestIDStore) {
    let guestStore = FakeLocalGuestIDStore(stored: guestID)
    let controller = IdentityController(
        authBackend: authBackend,
        ownershipMigration: ownershipMigration,
        localGuestIDStore: guestStore,
        anonymousSignInTimeout: timeout
    )
    return (controller, authBackend, ownershipMigration, guestStore)
}

// MARK: - Bootstrap

@Test func bootstrapRestoresAnAccountSessionWithoutAttemptingAnonymousSignIn() async {
    let backend = FakeAuthBackend(currentSession: accountSession(userID: "acct-1"))
    let fixture = makeController(authBackend: backend)

    await fixture.controller.bootstrap()

    #expect(fixture.controller.identity == .account(userID: "acct-1", email: "person@example.com"))
    #expect(fixture.controller.isBootstrapped)
    #expect(await backend.signInAnonymouslyCallCount == 0)
}

@Test func bootstrapWithNoSessionAndNoStoredGuestStaysUnresolvedAndCallsNothing() async {
    // RN boots to identityKind 'none' and identity first appears when
    // onboarding asks for it — bootstrap itself must never mint one.
    let backend = FakeAuthBackend(currentSession: nil, signInAnonymously: .succeed(anonymousSession(userID: "anon-9")))
    let fixture = makeController(authBackend: backend)

    await fixture.controller.bootstrap()

    #expect(fixture.controller.identity == .unresolved)
    #expect(fixture.controller.isBootstrapped)
    #expect(await backend.signInAnonymouslyCallCount == 0)
    #expect(try fixture.guestStore.read() == nil)
}

@Test func beginAnonymousSessionSignsInAnonymouslyFromUnresolved() async {
    let backend = FakeAuthBackend(currentSession: nil, signInAnonymously: .succeed(anonymousSession(userID: "anon-9")))
    let fixture = makeController(authBackend: backend)
    await fixture.controller.bootstrap()

    await fixture.controller.beginAnonymousSession()

    #expect(fixture.controller.identity == .anonymous(userID: "anon-9"))
    #expect(try fixture.guestStore.read() == nil, "a real anonymous session should not be persisted as a local guest id")
}

@Test func beginAnonymousSessionFallsBackToALocalGuestWhenAnonymousSignInTimesOut() async {
    let backend = FakeAuthBackend(currentSession: nil, signInAnonymously: .hang)
    let fixture = makeController(authBackend: backend, timeout: .milliseconds(20))
    await fixture.controller.bootstrap()

    await fixture.controller.beginAnonymousSession()

    guard case .localGuest(let userID) = fixture.controller.identity else {
        Issue.record("expected .localGuest, got \(fixture.controller.identity)")
        return
    }
    #expect(LocalGuestID.isLocalGuestID(userID))
    #expect(try fixture.guestStore.read() == userID)
}

@Test func bootstrapRestoresAStoredLocalGuestWithoutAnyNetworkCall() async {
    let backend = FakeAuthBackend(currentSession: nil)
    let fixture = makeController(authBackend: backend, guestID: "local-guest-resumed")

    await fixture.controller.bootstrap()

    #expect(fixture.controller.identity == .localGuest(userID: "local-guest-resumed"))
    #expect(await backend.signInAnonymouslyCallCount == 0)
}

// MARK: - ensureLocalGuestSession / beginAnonymousSession

@Test func ensureLocalGuestSessionReusesAnAlreadyStoredID() async {
    let fixture = makeController(guestID: "local-guest-existing")

    let userID = await fixture.controller.ensureLocalGuestSession()

    #expect(userID == "local-guest-existing")
    #expect(fixture.controller.identity == .localGuest(userID: "local-guest-existing"))
}

@Test func ensureLocalGuestSessionGeneratesAndPersistsANewIDWhenNoneStored() async {
    let fixture = makeController()

    let userID = await fixture.controller.ensureLocalGuestSession()

    #expect(LocalGuestID.isLocalGuestID(userID))
    #expect(try fixture.guestStore.read() == userID)
    #expect(fixture.controller.identity == .localGuest(userID: userID))
}

@Test func beginAnonymousSessionIsANoOpWhenAlreadyLocalGuest() async {
    let backend = FakeAuthBackend()
    let fixture = makeController(authBackend: backend)
    _ = await fixture.controller.ensureLocalGuestSession()

    await fixture.controller.beginAnonymousSession()

    #expect(await backend.signInAnonymouslyCallCount == 0)
}

@Test func beginAnonymousSessionIsANoOpForAnAccount() async {
    // signInAnonymously() on top of a live account session would replace
    // it with a fresh anonymous user — silently signing the account out.
    let backend = FakeAuthBackend(currentSession: accountSession(userID: "acct-1"), signInAnonymously: .succeed(anonymousSession(userID: "anon-1")))
    let fixture = makeController(authBackend: backend)
    await fixture.controller.bootstrap()

    await fixture.controller.beginAnonymousSession()

    #expect(await backend.signInAnonymouslyCallCount == 0)
    #expect(fixture.controller.identity == .account(userID: "acct-1", email: "person@example.com"))
}

@Test func hydratingAnAnonymousSessionOverAStoredGuestMigratesTheGuestsRows() async {
    // RN's stored-guest hydration branch keys on the session's user id,
    // not on account-ness: a stored local guest's rows move into a
    // Supabase-anonymous session too, and the stored id is cleared. This
    // happens when bootstrap restores an anonymous session while a guest
    // id is stored — e.g. an earlier anonymous sign-in that timed out
    // client-side (falling back to a local guest) but actually succeeded
    // server-side, leaving a persisted session for the next launch.
    let backend = FakeAuthBackend(currentSession: anonymousSession(userID: "anon-5"))
    let migration = FakeOwnershipMigration()
    let fixture = makeController(authBackend: backend, ownershipMigration: migration, guestID: "local-guest-4")

    await fixture.controller.bootstrap()

    #expect(fixture.controller.identity == .anonymous(userID: "anon-5"))
    let calls = migration.runMigrationCalls
    #expect(calls.count == 1)
    #expect(calls.first?.fromUserID == "local-guest-4")
    #expect(calls.first?.toUserID == "anon-5")
    #expect(calls.first?.source.hasSuffix("-stored-guest") == true)
    #expect(try fixture.guestStore.read() == nil)
}

// MARK: - Sign in / sign up ordering and migration

@Test func signInMigratesAStoredGuestAndClearsItsMarker() async {
    let backend = FakeAuthBackend(signInResult: .success(accountSession(userID: "acct-1")))
    let migration = FakeOwnershipMigration()
    let fixture = makeController(authBackend: backend, ownershipMigration: migration, guestID: "local-guest-1")

    _ = try? await fixture.controller.signIn(email: "a@b.com", password: "hunter2")

    #expect(fixture.controller.identity == .account(userID: "acct-1", email: "person@example.com"))
    let calls = migration.runMigrationCalls
    #expect(calls.count == 1)
    #expect(calls.first?.fromUserID == "local-guest-1")
    #expect(calls.first?.toUserID == "acct-1")
    #expect(calls.first?.source.hasSuffix("-stored-guest") == true)
    #expect(try fixture.guestStore.read() == nil)
}

@Test func signInMigratesAnInMemoryAnonymousIdentityWhenNoStoredGuestExists() async {
    let backend = FakeAuthBackend(currentSession: nil, signInAnonymously: .succeed(anonymousSession(userID: "anon-1")))
    let migration = FakeOwnershipMigration()
    let fixture = makeController(authBackend: backend, ownershipMigration: migration)
    await fixture.controller.bootstrap()
    await fixture.controller.beginAnonymousSession()
    #expect(fixture.controller.identity == .anonymous(userID: "anon-1"))

    await backend.setSignInResult(.success(accountSession(userID: "acct-2")))
    _ = try? await fixture.controller.signIn(email: "a@b.com", password: "hunter2")

    let calls = migration.runMigrationCalls
    #expect(calls.count == 1)
    #expect(calls.first?.fromUserID == "anon-1")
    #expect(calls.first?.toUserID == "acct-2")
    #expect(calls.first?.source.hasSuffix("-anonymous") == true)
}

@Test func everyHydrationResumesAnyPendingMigrationFirst() async {
    let backend = FakeAuthBackend(signInResult: .success(accountSession(userID: "acct-1")))
    let migration = FakeOwnershipMigration()
    let fixture = makeController(authBackend: backend, ownershipMigration: migration)

    _ = try? await fixture.controller.signIn(email: "a@b.com", password: "hunter2")

    let resumeCalls = migration.resumeCalls
    #expect(resumeCalls.count == 1)
    #expect(resumeCalls.first?.currentIdentity == .account(userID: "acct-1", email: "person@example.com"))
    #expect(resumeCalls.first?.source.hasSuffix("-resume") == true)
}

@Test func signUpThrowsWhenSupabaseDoesNotOpenASession() async {
    let backend = FakeAuthBackend(signUpResult: .success(nil))
    let fixture = makeController(authBackend: backend)

    await #expect(throws: IdentityController.SignUpError.didNotOpenASession) {
        _ = try await fixture.controller.signUp(email: "a@b.com", password: "hunter2")
    }
    #expect(fixture.controller.identity == .unresolved)
}

@Test func signUpHydratesOnASuccessfulSession() async {
    let backend = FakeAuthBackend(signUpResult: .success(accountSession(userID: "acct-3")))
    let fixture = makeController(authBackend: backend)

    let identity = try? await fixture.controller.signUp(email: "a@b.com", password: "hunter2")

    #expect(identity == .account(userID: "acct-3", email: "person@example.com"))
}

// MARK: - Sign out strands rows

@Test func signOutEndsTheSessionWithoutClearingLocalData() async {
    let backend = FakeAuthBackend(currentSession: accountSession(userID: "acct-1"))
    let migration = FakeOwnershipMigration()
    let fixture = makeController(authBackend: backend, ownershipMigration: migration)
    await fixture.controller.bootstrap()

    let log = CallLog()
    fixture.controller.onSignedOut = { log.record("signed-out") }

    try? await fixture.controller.signOut()

    #expect(await backend.signOutCallCount == 1)
    #expect(log.events == ["signed-out"])
    #expect(migration.clearAllLocalDataCallCount == 0, "sign-out must strand rows, not wipe them")
    #expect(fixture.controller.identity == .unresolved)
}

// MARK: - Delete account

@Test func deleteAccountThrowsWhenNoRemoteDeleteIsConfigured() async {
    let migration = FakeOwnershipMigration()
    let fixture = makeController(ownershipMigration: migration)

    await #expect(throws: IdentityController.DeleteAccountError.noRemoteDeleteConfigured) {
        try await fixture.controller.deleteAccount()
    }
    #expect(migration.clearAllLocalDataCallCount == 0)
}

@Test func deleteAccountRunsRemoteDeleteThenClearsLocalDataThenSignsOut() async {
    let backend = FakeAuthBackend(currentSession: accountSession(userID: "acct-1"))
    let migration = FakeOwnershipMigration()
    let fixture = makeController(authBackend: backend, ownershipMigration: migration)
    await fixture.controller.bootstrap()

    let log = CallLog()
    fixture.controller.deleteRemoteAccountData = { log.record("remote-delete") }
    fixture.controller.onClearingLocalData = { log.record("clearing") }
    fixture.controller.onSignedOut = { log.record("signed-out") }

    try? await fixture.controller.deleteAccount()

    #expect(log.events == ["remote-delete", "clearing", "signed-out"])
    #expect(migration.clearAllLocalDataCallCount == 1)
    #expect(await backend.signOutCallCount == 1)
}

// MARK: - Ownership migration retry

@Test func retryOwnershipMigrationClearsThePendingFlagOnSuccess() async {
    let migration = FakeOwnershipMigration(hasPending: true, resumeOutcome: (.succeeded, "guest-1", "acct-1"))
    let fixture = makeController(ownershipMigration: migration)

    await fixture.controller.retryOwnershipMigration()

    #expect(fixture.controller.ownershipMigrationPending == false)
}

@Test func retryOwnershipMigrationLeavesThePendingFlagSetWhenStillDeferred() async {
    let migration = FakeOwnershipMigration(hasPending: true, resumeOutcome: (.deferred, "guest-1", "acct-1"))
    let fixture = makeController(ownershipMigration: migration)

    await fixture.controller.retryOwnershipMigration()

    #expect(fixture.controller.ownershipMigrationPending == true)
}

// MARK: - Deep links

@Test func handleAuthDeepLinkReturnsNotAuthLinkForAnOrdinaryURL() async {
    let fixture = makeController()

    let outcome = await fixture.controller.handleAuthDeepLink(URL(string: "relora://home")!)

    #expect(outcome == .notAuthLink)
    #expect(fixture.controller.identity == .unresolved)
}

@Test func handleAuthDeepLinkEstablishesASessionForACodeLink() async {
    let backend = FakeAuthBackend(sessionFromURLResult: .success(accountSession(userID: "acct-7")))
    let fixture = makeController(authBackend: backend)

    let outcome = await fixture.controller.handleAuthDeepLink(URL(string: "relora://auth-callback?code=abc123")!)

    #expect(outcome == .sessionEstablished(isPasswordRecovery: false))
    #expect(fixture.controller.identity == .account(userID: "acct-7", email: "person@example.com"))
}

@Test func handleAuthDeepLinkFlagsPasswordRecoveryOnSuccess() async {
    let backend = FakeAuthBackend(sessionFromURLResult: .success(accountSession(userID: "acct-8")))
    let fixture = makeController(authBackend: backend)
    let url = URL(string: "relora://reset-password#access_token=a&refresh_token=b&type=recovery")!

    let outcome = await fixture.controller.handleAuthDeepLink(url)

    #expect(outcome == .sessionEstablished(isPasswordRecovery: true))
    #expect(fixture.controller.passwordRecoveryStatus == .pending)
}

@Test func handleAuthDeepLinkReportsPasswordRecoveryFailedWhenTheLinkCannotEstablishASession() async {
    let backend = FakeAuthBackend(sessionFromURLResult: .failure(FakeAuthError()))
    let fixture = makeController(authBackend: backend)
    let url = URL(string: "relora://reset-password#access_token=a&refresh_token=b&type=recovery")!

    let outcome = await fixture.controller.handleAuthDeepLink(url)

    #expect(outcome == .passwordRecoveryFailed)
    #expect(fixture.controller.passwordRecoveryStatus == .error)
}

@Test func handleAuthDeepLinkReportsFailedForANonRecoveryLinkThatCannotEstablishASession() async {
    let backend = FakeAuthBackend(sessionFromURLResult: .failure(FakeAuthError()))
    let fixture = makeController(authBackend: backend)

    let outcome = await fixture.controller.handleAuthDeepLink(URL(string: "relora://auth-callback?code=abc123")!)

    guard case .failed = outcome else {
        Issue.record("expected .failed, got \(outcome)")
        return
    }
    #expect(fixture.controller.passwordRecoveryStatus == .idle)
}

// MARK: - AuthDeepLink.classify (pure)

@Test func classifyRecognizesACodeLinkAsNeverPasswordRecovery() {
    let outcome = AuthDeepLink.classify(URL(string: "relora://auth-callback?code=xyz")!)
    #expect(outcome == .authLink(isPasswordRecovery: false))
}

@Test func classifyRecognizesARecoveryTypedFragmentLink() {
    let outcome = AuthDeepLink.classify(URL(string: "relora://reset-password#access_token=a&refresh_token=b&type=recovery")!)
    #expect(outcome == .authLink(isPasswordRecovery: true))
}

@Test func classifyRecognizesANonRecoveryTokenLinkAsAuthButNotRecovery() {
    let outcome = AuthDeepLink.classify(URL(string: "relora://auth-callback?access_token=a&refresh_token=b")!)
    #expect(outcome == .authLink(isPasswordRecovery: false))
}

@Test func classifyReturnsNotAuthLinkWithNoRecognizedParameters() {
    let outcome = AuthDeepLink.classify(URL(string: "relora://home")!)
    #expect(outcome == .notAuthLink)
}

// MARK: - AccessTokenProvider

@Test func accessTokenReadsThroughToTheBackendsCurrentSession() async throws {
    let backend = FakeAuthBackend(currentSession: accountSession(userID: "acct-1"))
    let fixture = makeController(authBackend: backend)

    let token = try await fixture.controller.accessToken()

    #expect(token == "access-acct-1")
}

@Test func accessTokenIsNilWhenThereIsNoSession() async throws {
    let fixture = makeController()

    let token = try await fixture.controller.accessToken()

    #expect(token == nil)
}

// MARK: - Identity.syncUserID

@Test func onlyAccountIdentityHasANonNilSyncUserID() {
    #expect(Identity.unresolved.syncUserID == nil)
    #expect(Identity.localGuest(userID: "local-guest-1").syncUserID == nil)
    #expect(Identity.anonymous(userID: "anon-1").syncUserID == nil)
    #expect(Identity.account(userID: "acct-1", email: nil).syncUserID == "acct-1")
}
