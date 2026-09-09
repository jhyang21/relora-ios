import Foundation
import Testing
import ReloraServices
@testable import ReloraFeatures

// MARK: - Fakes

private struct FakeAuthError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

private extension AuthSession {
    static let stub = AuthSession(
        user: AuthUser(id: "user-1", email: "ada@example.com", isAnonymous: false),
        accessToken: "access",
        refreshToken: "refresh"
    )
}

/// A backend whose every answer the test writes first, and which records the
/// addresses it was handed so the trimming rule can be checked at the seam it
/// actually matters at.
///
/// A lock-guarded class rather than an actor, matching `FakeOwnershipMigration`
/// in IdentityControllerTests.swift: the tests read its counters from the main
/// actor between awaits, and an actor would need one more `await` at every
/// assertion.
private final class ScriptedAuthBackend: AuthBackend, @unchecked Sendable {
    private let lock = NSLock()

    private var _signUpResult: Result<AuthSession?, Error> = .success(.stub)
    private var _signInResult: Result<AuthSession, Error> = .success(.stub)
    private var _resetResult: Result<Void, Error> = .success(())
    private var _signUpEmails: [String] = []
    private var _signInEmails: [String] = []
    private var _resetEmails: [String] = []

    /// Holds the next call inside the backend so a test can observe the view
    /// model mid-flight. Every waiter resumes on `release()`.
    private var _isHeld = false
    private var _waiters: [CheckedContinuation<Void, Never>] = []

    var signUpEmails: [String] { lock.withLock { _signUpEmails } }
    var signInEmails: [String] { lock.withLock { _signInEmails } }
    var resetEmails: [String] { lock.withLock { _resetEmails } }

    func setSignUpResult(_ result: Result<AuthSession?, Error>) { lock.withLock { _signUpResult = result } }
    func setSignInResult(_ result: Result<AuthSession, Error>) { lock.withLock { _signInResult = result } }
    func setResetResult(_ result: Result<Void, Error>) { lock.withLock { _resetResult = result } }

    func hold() { lock.withLock { _isHeld = true } }

    func release() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            _isHeld = false
            let pending = _waiters
            _waiters = []
            return pending
        }
        waiters.forEach { $0.resume() }
    }

    private func waitIfHeld() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let held: Bool = lock.withLock {
                guard _isHeld else { return false }
                _waiters.append(continuation)
                return true
            }
            if !held { continuation.resume() }
        }
    }

    func currentSession() async throws -> AuthSession? { nil }
    func signInAnonymously() async throws -> AuthSession { throw FakeAuthError(text: "unsupported") }

    func signUp(email: String, password: String) async throws -> AuthSession? {
        lock.withLock { _signUpEmails.append(email) }
        await waitIfHeld()
        return try lock.withLock { _signUpResult }.get()
    }

    func signIn(email: String, password: String) async throws -> AuthSession {
        lock.withLock { _signInEmails.append(email) }
        await waitIfHeld()
        return try lock.withLock { _signInResult }.get()
    }

    func signOut() async throws {}

    func resetPassword(email: String, redirectTo: URL?) async throws {
        lock.withLock { _resetEmails.append(email) }
        await waitIfHeld()
        try lock.withLock { _resetResult }.get()
    }

    func updatePassword(_ newPassword: String) async throws {}
    func sessionFromURL(_ url: URL) async throws -> AuthSession { throw FakeAuthError(text: "unsupported") }
}

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
private func makeViewModel(
    backend: ScriptedAuthBackend,
    context: AuthGateContext = .settings
) -> AuthViewModel {
    let identity = IdentityController(
        authBackend: backend,
        ownershipMigration: NoOpOwnershipMigration(),
        localGuestIDStore: NoOpLocalGuestIDStore()
    )
    return AuthViewModel(context: context, identity: identity)
}

/// Spins until `condition` holds, giving the main actor up to whatever else
/// is queued on it each time round. Bounded, so a broken expectation fails the
/// test rather than hanging CI.
@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

// MARK: - Mode

@MainActor
@Suite("AuthViewModel mode")
struct AuthViewModelModeTests {

    @Test("The caller decides which of the two the screen opens as")
    func initialModeComesFromContext() {
        let backend = ScriptedAuthBackend()

        let onboarding = makeViewModel(
            backend: backend,
            context: AuthGateContext(action: .signIn, source: .onboarding)
        )
        #expect(onboarding.mode == .createAccount)

        let purchase = makeViewModel(
            backend: backend,
            context: AuthGateContext(action: .purchase, source: .paywall)
        )
        #expect(purchase.mode == .createAccount)

        let voice = makeViewModel(
            backend: backend,
            context: AuthGateContext(action: .signIn, source: .voiceCapture)
        )
        #expect(voice.mode == .signIn)

        #expect(makeViewModel(backend: backend).mode == .signIn)
    }

    @Test("An explicit mode wins over the derived one")
    func explicitModeWins() {
        let context = AuthGateContext(action: .purchase, source: .paywall, initialMode: .signIn)
        #expect(makeViewModel(backend: ScriptedAuthBackend(), context: context).mode == .signIn)
    }

    /// The recovery path for the commonest failure on the screen: the address
    /// is taken, so switch, and everything already typed is still there.
    @Test("Switching keeps both fields")
    func switchingKeepsInput() {
        let viewModel = makeViewModel(backend: ScriptedAuthBackend())
        viewModel.email = "ada@example.com"
        viewModel.password = "Password1"

        viewModel.switchMode()

        #expect(viewModel.mode == .createAccount)
        #expect(viewModel.email == "ada@example.com")
        #expect(viewModel.password == "Password1")
    }

    @Test("The password rule is only shown to somebody choosing a password")
    func passwordRuleOnlyInCreateMode() {
        let viewModel = makeViewModel(backend: ScriptedAuthBackend())
        #expect(!viewModel.showsPasswordRule)
        viewModel.switchMode()
        #expect(viewModel.showsPasswordRule)
    }
}

// MARK: - Validation

@MainActor
@Suite("AuthViewModel validation")
struct AuthViewModelValidationTests {

    @Test("An empty email is caught before the round trip")
    func rejectsEmptyEmail() async {
        let backend = ScriptedAuthBackend()
        let viewModel = makeViewModel(backend: backend)
        viewModel.password = "Password1"

        #expect(await viewModel.submit() == false)
        #expect(viewModel.emailError != nil)
        #expect(viewModel.focusRequest == .email)
        #expect(backend.signInEmails.isEmpty)
    }

    @Test("A malformed email is caught before the round trip")
    func rejectsMalformedEmail() async {
        let backend = ScriptedAuthBackend()
        let viewModel = makeViewModel(backend: backend)
        viewModel.email = "ada@example"
        viewModel.password = "Password1"

        #expect(await viewModel.submit() == false)
        #expect(viewModel.emailError != nil)
        #expect(backend.signInEmails.isEmpty)
    }

    @Test("An empty password is caught before the round trip")
    func rejectsEmptyPassword() async {
        let backend = ScriptedAuthBackend()
        let viewModel = makeViewModel(backend: backend)
        viewModel.email = "ada@example.com"

        #expect(await viewModel.submit() == false)
        #expect(viewModel.passwordError != nil)
        #expect(viewModel.focusRequest == .password)
        #expect(backend.signInEmails.isEmpty)
    }

    @Test("A weak new password is caught before the round trip")
    func rejectsWeakNewPassword() async {
        let backend = ScriptedAuthBackend()
        let viewModel = makeViewModel(
            backend: backend,
            context: AuthGateContext(action: .signIn, source: .onboarding)
        )
        viewModel.email = "ada@example.com"
        viewModel.password = "short"

        #expect(await viewModel.submit() == false)
        #expect(viewModel.passwordError == PasswordRule.hint)
        #expect(backend.signUpEmails.isEmpty)
    }

    /// The rule belongs to a password being chosen. Applying it on sign-in
    /// would lock out anybody whose account predates it.
    @Test("Signing in never applies the new-password rule")
    func signInIgnoresThePasswordRule() async {
        let backend = ScriptedAuthBackend()
        let viewModel = makeViewModel(backend: backend)
        viewModel.email = "ada@example.com"
        viewModel.password = "short"

        #expect(await viewModel.submit() == true)
        #expect(backend.signInEmails == ["ada@example.com"])
    }

    /// Problem 4 in the redesign brief: the old screen trimmed on reset and
    /// nowhere else, so a pasted address failed auth with an opaque message.
    @Test("A pasted address is trimmed on every call that sends one")
    func trimsBeforeSending() async {
        let backend = ScriptedAuthBackend()
        let viewModel = makeViewModel(backend: backend)
        viewModel.email = "  ada@example.com \n"
        viewModel.password = "Password1"

        await viewModel.submit()
        await viewModel.sendPasswordReset()
        viewModel.switchMode()
        await viewModel.submit()

        #expect(backend.signInEmails == ["ada@example.com"])
        #expect(backend.resetEmails == ["ada@example.com"])
        #expect(backend.signUpEmails == ["ada@example.com"])
    }

    @Test("Editing a field clears the error describing it")
    func editingClearsErrors() async {
        let viewModel = makeViewModel(backend: ScriptedAuthBackend())
        viewModel.password = "Password1"
        await viewModel.submit()
        #expect(viewModel.emailError != nil)

        viewModel.email = "a"
        viewModel.inputChanged()

        #expect(viewModel.emailError == nil)
    }
}

// MARK: - Failures

@MainActor
@Suite("AuthViewModel failures")
struct AuthViewModelFailureTests {

    @Test("A wrong password reads as a pair, and the sheet stays open")
    func wrongPassword() async {
        let backend = ScriptedAuthBackend()
        backend.setSignInResult(.failure(FakeAuthError(text: "Invalid login credentials")))
        let viewModel = makeViewModel(backend: backend)
        viewModel.email = "ada@example.com"
        viewModel.password = "Password1"

        #expect(await viewModel.submit() == false)
        #expect(viewModel.formError?.message == AuthErrorCopy.Message.badCredentials)
        #expect(viewModel.formError?.recovery == .forgotPassword)
    }

    /// The dead end the old screen left: a taken address failed with a raw
    /// server string and no way forward. Now it offers the one move that
    /// works, and taking it keeps the credentials.
    @Test("A taken address offers the switch, and the switch keeps the input")
    func takenAddressOffersTheSwitch() async {
        let backend = ScriptedAuthBackend()
        backend.setSignUpResult(.failure(FakeAuthError(text: "User already registered")))
        let viewModel = makeViewModel(
            backend: backend,
            context: AuthGateContext(action: .signIn, source: .onboarding)
        )
        viewModel.email = "ada@example.com"
        viewModel.password = "Password1"

        #expect(await viewModel.submit() == false)
        #expect(viewModel.formError?.message == AuthErrorCopy.Message.alreadyRegistered)

        guard let recovery = viewModel.formError?.recovery else {
            Issue.record("Expected a recovery offer")
            return
        }
        await viewModel.applyRecovery(recovery)

        #expect(viewModel.mode == .signIn)
        #expect(viewModel.email == "ada@example.com")
        #expect(viewModel.password == "Password1")
        #expect(viewModel.formError == nil)
    }

    @Test("A sign-up that opens no session becomes the confirmation notice")
    func confirmationRequired() async {
        let backend = ScriptedAuthBackend()
        backend.setSignUpResult(.success(nil))
        let viewModel = makeViewModel(
            backend: backend,
            context: AuthGateContext(action: .signIn, source: .onboarding)
        )
        viewModel.email = "ada@example.com"
        viewModel.password = "Password1"

        #expect(await viewModel.submit() == false)
        #expect(viewModel.notice == .confirmationSent(email: "ada@example.com"))
        #expect(viewModel.formError == nil)
        #expect(viewModel.password.isEmpty)
    }
}

// MARK: - Password reset

@MainActor
@Suite("AuthViewModel password reset")
struct AuthViewModelResetTests {

    /// The old screen refused and told the user to type their address above
    /// first, while their address was sitting above.
    @Test("The reset uses the address already in the field")
    func usesTheAddressOnScreen() async {
        let backend = ScriptedAuthBackend()
        let viewModel = makeViewModel(backend: backend)
        viewModel.email = "ada@example.com"

        await viewModel.sendPasswordReset()

        #expect(backend.resetEmails == ["ada@example.com"])
        #expect(viewModel.notice == .resetSent(email: "ada@example.com"))
    }

    @Test("An empty field is asked for, not scolded, and nothing is sent")
    func asksForAnEmptyField() async {
        let backend = ScriptedAuthBackend()
        let viewModel = makeViewModel(backend: backend)

        await viewModel.sendPasswordReset()

        #expect(backend.resetEmails.isEmpty)
        #expect(viewModel.emailError == AuthCopy.emailMissing)
        #expect(viewModel.focusRequest == .email)
        #expect(viewModel.notice == nil)
    }

    /// "Do not falsely tell the user an email was sent unless the request
    /// actually succeeded."
    @Test("A failed request never claims mail was sent")
    func failureNeverClaimsSuccess() async {
        let backend = ScriptedAuthBackend()
        backend.setResetResult(.failure(FakeAuthError(text: "User not found")))
        let viewModel = makeViewModel(backend: backend)
        viewModel.email = "ada@example.com"

        await viewModel.sendPasswordReset()

        #expect(viewModel.notice == nil)
        #expect(viewModel.formError?.message == AuthErrorCopy.Message.generic)
    }
}

// MARK: - In-flight guard

@MainActor
@Suite("AuthViewModel in-flight guard")
struct AuthViewModelInFlightTests {

    @Test("A second submit while the first is in flight is refused")
    func refusesDuplicateSubmits() async {
        let backend = ScriptedAuthBackend()
        backend.hold()
        let viewModel = makeViewModel(backend: backend)
        viewModel.email = "ada@example.com"
        viewModel.password = "Password1"

        let first = Task { await viewModel.submit() }
        #expect(await waitUntil { backend.signInEmails.count == 1 })

        #expect(await viewModel.submit() == false)
        #expect(backend.signInEmails.count == 1)

        backend.release()
        #expect(await first.value == true)
    }

    @Test("Forgot password is refused while a submit is in flight")
    func refusesResetDuringSubmit() async {
        let backend = ScriptedAuthBackend()
        backend.hold()
        let viewModel = makeViewModel(backend: backend)
        viewModel.email = "ada@example.com"
        viewModel.password = "Password1"

        let first = Task { await viewModel.submit() }
        #expect(await waitUntil { backend.signInEmails.count == 1 })

        await viewModel.sendPasswordReset()
        #expect(backend.resetEmails.isEmpty)

        backend.release()
        _ = await first.value
    }
}
