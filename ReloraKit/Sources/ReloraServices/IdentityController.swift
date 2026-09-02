import Foundation
import Observation
import ReloraCore

/// Owns the app's identity — restoring a session at launch, driving the
/// guest → account ownership migration around every sign-in, and exposing
/// the sign-up/sign-in/sign-out/delete-account/password-reset/deep-link
/// flows those transitions go through. Ports the state machine spread
/// across apps/mobile/src/state/authState.ts and authLogic.ts.
///
/// Deliberately does not import ReloraData, or a sync or notification
/// layer: everything those layers need to react to (an identity being
/// applied, a sign-out, local data about to be cleared) is exposed as an
/// injected closure, and the two seams that need real durable storage
/// (`OwnershipMigrating`, `LocalGuestIDStore` — see Identity.swift) are
/// injected as protocols a composition root satisfies with
/// `IdentityLocalDataBackend.swift`'s ReloraData-backed adapters. This
/// keeps `IdentityController` — and, as important, `ReloraServicesTests`,
/// which depends on `ReloraCore` but not `ReloraData` (`Package.swift`) —
/// free of that dependency.
// `Sendable` is required here, not just convenient: `AccessTokenProvider`
// (ReloraCore/Backend.swift) refines `Sendable`, and this class conforms to
// it below. A plain class with mutable `var` state could not make this
// claim safely, but a class isolated to a global actor can — `@MainActor`
// guarantees every read and write of that state is serialized through the
// same actor, which is exactly what `Sendable` needs to be true here.
@MainActor
@Observable
public final class IdentityController: Sendable {
    public private(set) var identity: Identity = .unresolved
    /// Mirrors RN's `authReady`: whether `identity` reflects a completed
    /// `bootstrap()` rather than its pre-launch default.
    public private(set) var isBootstrapped: Bool = false
    /// Whether a guest → account migration is stranded, waiting for a
    /// retry. Drives the RN equivalent of a "still syncing your data"
    /// banner. Mirrors `hasPendingOwnershipMigration`.
    public private(set) var ownershipMigrationPending: Bool = false
    public private(set) var passwordRecoveryStatus: PasswordRecoveryStatus = .idle

    private let authBackend: any AuthBackend
    private let ownershipMigration: any OwnershipMigrating
    private let localGuestIDStore: any LocalGuestIDStore
    private let anonymousSignInTimeout: Duration

    /// Runs after `identity` changes and is persisted, so features that
    /// depend on this controller (data refresh, sync queuing, notification
    /// rescheduling) can react without this module importing them. Mirrors
    /// the tail of `runHydrateSession` (refresh / queueSync / reschedule
    /// notifications on a real identity; reset / clear on `'none'`) —
    /// callers branch on the `Identity` they're handed to tell the two
    /// apart. Not called for the boring "still unresolved" non-transition
    /// on a fresh install's very first hydration.
    public var onIdentityApplied: (@Sendable (Identity) async -> Void)?
    /// Called once sign-out has actually succeeded. Mirrors
    /// `disableReminderNotifications` in `signOutOfAccount`
    /// (dataControls.ts) — cancels scheduled reminder notifications. A
    /// failure there never fails sign-out in RN; this hook has no return
    /// value for the same reason.
    public var onSignedOut: (@Sendable () async -> Void)?
    /// Called before local data is wiped in `deleteAccount()`. Mirrors
    /// `cancelAllScheduledNotificationsAsync()`, the first line of
    /// `clearLocalData` (dataControls.ts).
    public var onClearingLocalData: (@Sendable () async -> Void)?
    /// Deletes server-side account data. Wire to
    /// `EdgeFunctionsClient.deleteAccountData`. `deleteAccount()` throws
    /// `DeleteAccountError.noRemoteDeleteConfigured` if this is never set —
    /// a missing wire-up should fail loudly, not silently skip the remote
    /// delete and only clear local data.
    public var deleteRemoteAccountData: (@Sendable () async throws -> Void)?

    /// Mirrors the `relora://reset-password` deep link RN's
    /// password-reset flow redirects to (the `relora` URL scheme).
    public static let passwordResetRedirectURL = URL(string: "relora://reset-password")!

    public init(
        authBackend: any AuthBackend,
        ownershipMigration: any OwnershipMigrating,
        localGuestIDStore: any LocalGuestIDStore,
        anonymousSignInTimeout: Duration = .milliseconds(3000)
    ) {
        self.authBackend = authBackend
        self.ownershipMigration = ownershipMigration
        self.localGuestIDStore = localGuestIDStore
        self.anonymousSignInTimeout = anonymousSignInTimeout
    }

    // MARK: - Bootstrap

    /// Restores whatever identity is available at launch: an existing
    /// Supabase session, else a stored local guest, else `.unresolved` —
    /// RN's `identityKind: 'none'`.
    ///
    /// Deliberately does NOT create an identity for a fresh install.
    /// Identity first appears when onboarding asks for it — the tutorial
    /// seed calls `ensureLocalGuestSession()`, GetStarted calls
    /// `beginAnonymousSession()` — and a user who skips stays at
    /// `.unresolved` (see `.claude/rules/onboarding.md`: "Skip does not
    /// create identity"). Creating one eagerly here would also mint a
    /// Supabase anonymous user for every install that never finishes
    /// onboarding. Until the onboarding flow exists (M10), the app shell
    /// may call `ensureLocalGuestSession()` after bootstrap as an interim
    /// step — that belongs in the composition root, not here.
    public func bootstrap() async {
        let session = try? await authBackend.currentSession()
        await hydrate(session: session, source: "bootstrap")

        ownershipMigrationPending = (try? ownershipMigration.hasPending()) ?? false
        isBootstrapped = true
    }

    /// Ports `ensureLocalAnonymousSession` (authState.ts): returns the
    /// current owner id if an identity already exists, otherwise
    /// persists/reuses a stored local guest id. No network call, unlike
    /// `beginAnonymousSession`.
    @discardableResult
    public func ensureLocalGuestSession() async -> String {
        guard case .unresolved = identity else {
            return identity.ownerUserID
        }
        let stored = try? localGuestIDStore.read()
        let userID = (stored?.isEmpty == false ? stored : nil) ?? LocalGuestID.generate()
        await activateLocalGuest(userID: userID, source: "ensure-local-guest")
        return userID
    }

    /// Ports `beginAnonymousSession` (authState.ts): a no-op if already
    /// anonymous or a local guest; otherwise races a real Supabase
    /// anonymous sign-in against `anonymousSignInTimeout`, falling back to
    /// a local guest on failure or timeout.
    ///
    /// Also a no-op for `.account` — a guard RN doesn't need (only
    /// onboarding calls it there, and an account never sees onboarding)
    /// but this public API does: `signInAnonymously()` on top of a live
    /// account session would replace that session with a fresh anonymous
    /// user, silently signing the account out.
    public func beginAnonymousSession() async {
        switch identity {
        case .anonymous, .localGuest, .account:
            return
        case .unresolved:
            await resolveAnonymousIdentity(source: "begin-anonymous-session")
        }
    }

    // MARK: - Sign in / up / out

    public enum SignUpError: Error, Sendable, Equatable {
        /// Supabase accepted the sign-up but did not open a session (e.g.
        /// email confirmation is required first).
        case didNotOpenASession
    }

    @discardableResult
    public func signUp(email: String, password: String) async throws -> Identity {
        guard let session = try await authBackend.signUp(email: email, password: password) else {
            throw SignUpError.didNotOpenASession
        }
        await hydrate(session: session, source: "sign-up")
        return identity
    }

    @discardableResult
    public func signIn(email: String, password: String) async throws -> Identity {
        let session = try await authBackend.signIn(email: email, password: password)
        await hydrate(session: session, source: "sign-in")
        return identity
    }

    /// Ends the session and returns identity to the bootstrap path,
    /// without touching local rows: they keep the signed-out account's
    /// `user_id` and reattach, dirty flags intact, on the next sign-in to
    /// the same account. Mirrors `signOutOfAccount` (dataControls.ts).
    ///
    /// If a stored local guest happens to exist, hydration restores it
    /// rather than settling on `.unresolved` — an edge case, but the
    /// faithful port of what `runHydrateSession` does with a `nil`
    /// session regardless of why it became `nil`.
    public func signOut() async throws {
        try await authBackend.signOut()
        await onSignedOut?()
        await hydrate(session: nil, source: "sign-out")
    }

    public enum DeleteAccountError: Error, Sendable, Equatable {
        case noRemoteDeleteConfigured
    }

    /// Deletes the remote account, clears all local data, and signs out —
    /// in that order, matching `deleteAccountAndData` (dataControls.ts)
    /// exactly: the remote delete happens first, so a failure there
    /// leaves local data intact rather than destroying it out from under
    /// a delete that never actually happened server-side. The actual
    /// table wipe is `GuestMigration.clearAllLocalData()`
    /// (ReloraData), reached through `ownershipMigration`.
    public func deleteAccount() async throws {
        guard let deleteRemoteAccountData else {
            throw DeleteAccountError.noRemoteDeleteConfigured
        }
        try await deleteRemoteAccountData()
        await onClearingLocalData?()
        try ownershipMigration.clearAllLocalData()
        try await signOut()
    }

    // MARK: - Password reset / deep links

    public func sendPasswordReset(email: String) async throws {
        try await authBackend.resetPassword(email: email, redirectTo: Self.passwordResetRedirectURL)
    }

    public func updatePassword(_ newPassword: String) async throws {
        try await authBackend.updatePassword(newPassword)
    }

    /// Classifies `url`, and — if it is a Supabase auth callback —
    /// establishes the session it carries and runs it through the normal
    /// hydration order. Ports `applyAuthDeepLink` (authDeepLink.ts).
    @discardableResult
    public func handleAuthDeepLink(_ url: URL) async -> AuthDeepLinkOutcome {
        guard case .authLink(let isPasswordRecovery) = AuthDeepLink.classify(url) else {
            return .notAuthLink
        }
        do {
            let session = try await authBackend.sessionFromURL(url)
            await hydrate(session: session, source: "deep-link")
            if isPasswordRecovery {
                passwordRecoveryStatus = .pending
            }
            return .sessionEstablished(isPasswordRecovery: isPasswordRecovery)
        } catch {
            if isPasswordRecovery {
                passwordRecoveryStatus = .error
                return .passwordRecoveryFailed
            }
            return .failed(AuthDeepLinkFailure(message: String(describing: error)))
        }
    }

    public func acknowledgePasswordRecovery() {
        passwordRecoveryStatus = .idle
    }

    // MARK: - Ownership migration retry

    /// Manually retries a stranded migration — e.g. from a "couldn't
    /// finish syncing your data, tap to retry" banner. Mirrors
    /// `retryOwnershipMigration` (authState.ts).
    public func retryOwnershipMigration() async {
        let result = await ownershipMigration.resumePendingMigrationIfAny(currentIdentity: identity, source: "manual-retry")
        // A success clears the flag outright and returns, as RN does: the
        // migration that just finished cleared its own marker, so re-reading
        // it would only risk turning the banner back on.
        if result.outcome == .succeeded {
            ownershipMigrationPending = false
            await onIdentityApplied?(identity)
            return
        }
        ownershipMigrationPending = (try? ownershipMigration.hasPending()) ?? false
    }

    // MARK: - Hydration

    /// Applies `session` (or its absence) to `identity`, running the
    /// ownership-migration hydration order first — resume a migration an
    /// earlier session couldn't finish, then migrate a stored guest or an
    /// in-memory anonymous/local-guest identity that is upgrading to this
    /// account — before ever calling `onIdentityApplied`. Ports
    /// `runHydrateSession` (authLogic.ts).
    private func hydrate(session: AuthSession?, source: String) async {
        let storedGuestID = try? localGuestIDStore.read()

        // No active session but a stored local guest exists — restore it
        // without touching the network or the migration machinery, same
        // as RN's restore-only branch.
        if session == nil, let storedGuestID, !storedGuestID.isEmpty {
            await activateLocalGuest(userID: storedGuestID, source: source)
            return
        }

        let previousIdentity = identity
        let nextIdentity = Self.identity(from: session)

        // The session's user id, whichever kind of session it is. The
        // stored-guest branches below key on this, not `syncUserID`: RN's
        // equivalents check `nextIdentity.userId`, which a Supabase
        // *anonymous* session has too — a stored guest's rows migrate into
        // an anonymous session just as they would into an account
        // (authLogic.ts, "Stored guest is upgrading" + the guest-id clear).
        // Only the in-memory-anonymous branch is account-gated in RN.
        let nextSessionUserID: String?
        switch nextIdentity {
        case .anonymous(let userID):
            nextSessionUserID = userID
        case .account(let userID, _):
            nextSessionUserID = userID
        case .unresolved, .localGuest:
            nextSessionUserID = nil
        }

        // A migration an earlier session could not finish still owns the
        // user's rows — retry it first. `resumePendingMigrationIfAny`
        // enforces that only an account may claim them.
        let resumed = await ownershipMigration.resumePendingMigrationIfAny(currentIdentity: nextIdentity, source: "\(source)-resume")
        applyMigrationOutcome(resumed.outcome)

        // A stored guest is upgrading to a real session (anonymous or
        // account — see `nextSessionUserID` above).
        if let storedGuestID, !storedGuestID.isEmpty, let toUserID = nextSessionUserID, storedGuestID != toUserID {
            applyMigrationOutcome(await ownershipMigration.runMigration(fromUserID: storedGuestID, toUserID: toUserID, source: "\(source)-stored-guest"))
        }

        // The in-memory identity from before this hydration is upgrading
        // to a real account. RN only checks `identityKind === 'anonymous'`
        // here; `.collapsingLocalGuest` covers this port's `.localGuest`
        // too, since RN flattens both into `'anonymous'`.
        if case .anonymous(let previousUserID) = previousIdentity.collapsingLocalGuest,
           let toUserID = nextIdentity.syncUserID,
           previousUserID != toUserID,
           previousUserID != storedGuestID {
            applyMigrationOutcome(await ownershipMigration.runMigration(fromUserID: previousUserID, toUserID: toUserID, source: "\(source)-anonymous"))
        }

        // Clear the stored guest id once it has handed off to a session.
        // A failed migration keeps its own pending marker, so dropping the
        // guest id here does not lose the retry path.
        if let storedGuestID, !storedGuestID.isEmpty, let toUserID = nextSessionUserID, storedGuestID != toUserID {
            try? localGuestIDStore.write(nil)
        }

        identity = nextIdentity
        if !(previousIdentity == .unresolved && nextIdentity == .unresolved) {
            await onIdentityApplied?(nextIdentity)
        }
    }

    private func activateLocalGuest(userID: String, source: String) async {
        let previousIdentity = identity
        try? localGuestIDStore.write(userID)
        identity = .localGuest(userID: userID)
        if previousIdentity != identity {
            await onIdentityApplied?(identity)
        }
    }

    /// Races `authBackend.signInAnonymously()` against
    /// `anonymousSignInTimeout`; on success, hydrates normally (which may
    /// trigger a migration if there was a prior guest/anonymous identity
    /// with rows to move). On timeout, offline, or a backend rejection,
    /// falls back to a local guest — reusing whatever id is already
    /// stored, mirroring `ensureLocalAnonymousSession`'s read-before-write.
    private func resolveAnonymousIdentity(source: String) async {
        do {
            let session = try await withTimeout(anonymousSignInTimeout) { [authBackend] in
                try await authBackend.signInAnonymously()
            }
            await hydrate(session: session, source: source)
        } catch {
            let stored = try? localGuestIDStore.read()
            let userID = (stored?.isEmpty == false ? stored : nil) ?? LocalGuestID.generate()
            await activateLocalGuest(userID: userID, source: "\(source)-fallback")
        }
    }

    private func applyMigrationOutcome(_ outcome: OwnershipMigrationOutcome) {
        switch outcome {
        case .skipped:
            return
        case .succeeded:
            ownershipMigrationPending = false
        case .deferred:
            ownershipMigrationPending = true
        }
    }

    private static func identity(from session: AuthSession?) -> Identity {
        guard let session else { return .unresolved }
        if session.user.isAnonymous {
            return .anonymous(userID: session.user.id)
        }
        return .account(userID: session.user.id, email: session.user.email)
    }

    private struct TimeoutError: Error, Sendable {}

    private func withTimeout<T: Sendable>(_ duration: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw TimeoutError()
            }
            return result
        }
    }
}

// MARK: - AccessTokenProvider

extension IdentityController: AccessTokenProvider {
    /// The current session's access token, `nil` when there is none (a
    /// local guest, or before any identity resolves). Refreshing, if the
    /// backend does that implicitly, happens inside
    /// `AuthBackend.currentSession()`.
    public func accessToken() async throws -> String? {
        try await authBackend.currentSession()?.accessToken
    }
}
