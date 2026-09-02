import Foundation
import ReloraCore
import ReloraData

// MARK: - Identity

/// The four states local data (and, for two of them, a Supabase session)
/// can be owned under. Ports RN's flat `IdentityKind`
/// (`'none' | 'anonymous' | 'account'`, apps/mobile/src/features/billing/types.ts)
/// with one addition: RN's `'anonymous'` covers two things this port keeps
/// distinct — a real Supabase anonymous session (`.anonymous`, has a
/// session and can sync) and a same-device-only fallback with no session
/// at all (`.localGuest`, RN's `local-guest-<uuid>` ids from
/// `LOCAL_GUEST_USER_PREFIX` in apps/mobile/src/features/billing/storage.ts).
/// RN's `activateLocalAnonymousIdentity` sets `identityKind: 'anonymous'`
/// for both, so `kind` below collapses them back for anything that reasons
/// about RN's flat shape (`GuestMigration`, in ReloraData).
///
/// `.unresolved` doubles as RN's `identityKind === 'none'`: RN's
/// `identityRef.current` starts pre-seeded at `{identityKind:'none',
/// userId:null}` — there is no separate "not yet booted" state in RN, only
/// a companion `authReady` boolean (mirrored by
/// `IdentityController.isBootstrapped`) that says whether the current
/// value is final. `.unresolved` plays both roles here too: the transient
/// pre-`bootstrap()` default, and the resolved "signed out, no identity"
/// state RN calls `'none'`.
public enum Identity: Sendable, Equatable {
    case unresolved
    case localGuest(userID: String)
    case anonymous(userID: String)
    case account(userID: String, email: String?)

    /// The id the sync engine uploads under. Non-nil ONLY for `.account` —
    /// mirrors the `getUserId` rule in AppContext.tsx
    /// (`identityRef.current.identityKind === 'account' ? userId : null`).
    /// A real anonymous Supabase session has a syncable `auth.users` row,
    /// but RN deliberately withholds it from the sync engine: anonymous
    /// identities are disposable local state, not data the server should
    /// accumulate for a session nobody has claimed.
    public var syncUserID: String? {
        if case .account(let userID, _) = self { return userID }
        return nil
    }

    /// The id that owns local rows in the current state. Every repository
    /// call and `GuestMigration` are scoped by this — a local guest and an
    /// anonymous session own their rows exactly as an account does; only
    /// *sync* is account-gated (see `syncUserID`).
    ///
    /// `.unresolved` has no owner and precondition-fails rather than
    /// returning a placeholder: a local write attempted before an
    /// identity resolves is a bug this API should surface loudly, not
    /// paper over with an empty-string id that would silently "work" as a
    /// SQL parameter. RN never reaches a data screen while
    /// `identityKind === 'none'` (onboarding routes around it — see
    /// `.claude/rules/onboarding.md`), so nothing in RN reads an owner id
    /// in this state either.
    public var ownerUserID: String {
        switch self {
        case .unresolved:
            preconditionFailure(
                "Identity.ownerUserID read while unresolved — establish a session " +
                "(IdentityController.bootstrap(), .ensureLocalGuestSession(), or a sign-in) first."
            )
        case .localGuest(let userID), .anonymous(let userID), .account(let userID, _):
            return userID
        }
    }

    /// Bridges to `ReloraData.IdentityKind`, the flat RN-shaped kind
    /// `GuestMigration` reasons about. See the type doc comment for why
    /// `.localGuest` and `.anonymous` both map to `.anonymous`.
    public var kind: IdentityKind {
        switch self {
        case .unresolved: return .none
        case .localGuest, .anonymous: return .anonymous
        case .account: return .account
        }
    }

    /// Normalizes `.localGuest` to `.anonymous` — for logic (the ownership
    /// migration's "previous identity was anonymous" check) that only
    /// cares about RN's flat `'anonymous'` kind, not which of the two
    /// native-only sub-states produced it.
    var collapsingLocalGuest: Identity {
        if case .localGuest(let userID) = self { return .anonymous(userID: userID) }
        return self
    }
}

/// Same-device-only guest ids. Mirrors `LOCAL_GUEST_USER_PREFIX` and
/// `generateId()`/`buildLocalAnonymousUserId` in
/// apps/mobile/src/features/billing/storage.ts and authState.ts.
public enum LocalGuestID {
    public static let prefix = "local-guest-"

    /// A new, unused local guest id.
    public static func generate() -> String {
        prefix + ReloraID.new()
    }

    public static func isLocalGuestID(_ userID: String) -> Bool {
        userID.hasPrefix(prefix)
    }
}

/// `.pending` opens a session from a password-recovery link and should
/// gate navigation onto a set-new-password screen (RN:
/// `resolveRootNavigationDecision`); `.error` means a recovery link was
/// recognized but failed to establish a session (already used or
/// expired). Mirrors `PasswordRecoveryStatus` in authState.ts.
public enum PasswordRecoveryStatus: Sendable, Equatable {
    case idle
    case pending
    case error
}

// MARK: - Auth deep links

/// Classifies a Supabase auth callback URL from its query string and
/// fragment alone — no network call. Ports `extractAuthPayload` in
/// apps/mobile/src/features/auth/authDeepLink.ts.
public enum AuthDeepLink {
    public enum Classification: Sendable, Equatable {
        case notAuthLink
        /// `isPasswordRecovery` mirrors the `type=recovery` marker
        /// Supabase's implicit-flow redirect appends to password-reset
        /// links specifically (as opposed to e.g. `type=signup`, or no
        /// type at all for a plain magic link). A PKCE `code` link is
        /// never a recovery link in this app — the mobile client runs the
        /// implicit flow (per authDeepLink.ts), so that branch exists in
        /// RN only in case that ever changes, and is mirrored here the
        /// same way: always `isPasswordRecovery: false`.
        case authLink(isPasswordRecovery: Bool)
    }

    public static func classify(_ url: URL) -> Classification {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            if let value = item.value { queryItems[item.name] = value }
        }
        let fragmentItems = parseFormEncoded(url.fragment ?? "")

        if queryItems["code"] != nil || fragmentItems["code"] != nil {
            return .authLink(isPasswordRecovery: false)
        }

        guard let accessToken = queryItems["access_token"] ?? fragmentItems["access_token"], !accessToken.isEmpty,
              let refreshToken = queryItems["refresh_token"] ?? fragmentItems["refresh_token"], !refreshToken.isEmpty
        else {
            return .notAuthLink
        }

        let linkType = queryItems["type"] ?? fragmentItems["type"]
        return .authLink(isPasswordRecovery: linkType == "recovery")
    }

    private static func parseFormEncoded(_ string: String) -> [String: String] {
        guard !string.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for pair in string.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first, !name.isEmpty else { continue }
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            let key = String(name).removingPercentEncoding ?? String(name)
            result[key] = rawValue.removingPercentEncoding ?? rawValue
        }
        return result
    }
}

/// A non-recovery auth link that failed to establish a session. Carries a
/// plain message rather than the original error so `AuthDeepLinkOutcome`
/// can stay `Equatable`/`Sendable` without knowing the concrete error type
/// an `AuthBackend` throws.
public struct AuthDeepLinkFailure: Error, Sendable, Equatable {
    public var message: String
    public init(message: String) {
        self.message = message
    }
}

/// Result of `IdentityController.handleAuthDeepLink`. Mirrors
/// `AuthDeepLinkResult` in authDeepLink.ts, split further so a caller can
/// distinguish a recognized-but-failed recovery link (RN's
/// `PasswordRecoveryLinkError`) from any other failure.
public enum AuthDeepLinkOutcome: Sendable, Equatable {
    case notAuthLink
    case sessionEstablished(isPasswordRecovery: Bool)
    /// A link that identified itself as a password-recovery link failed to
    /// establish a session — already used, or expired. Mirrors
    /// `PasswordRecoveryLinkError` in authDeepLink.ts: tagged separately so
    /// the caller can show "request a new link" instead of a plain
    /// sign-in failure.
    case passwordRecoveryFailed
    /// A non-recovery auth link failed to establish a session. RN
    /// rethrows this to its caller, which only logs it — there is no
    /// dedicated UI state for it in RN either.
    case failed(AuthDeepLinkFailure)
}

// MARK: - Ownership migration / local storage seams

/// `succeeded` — rows now belong to the account. `deferred` — the attempt
/// failed; a marker survives (durably, in ReloraData) and the next
/// hydration retries. `skipped` — nothing to do. `ReloraServices`' own
/// mirror of `ReloraData.MigrationOutcome`, so `OwnershipMigrating`'s
/// requirements — and a fake conforming to it in tests — never need to
/// name a ReloraData type directly. `OwnershipMigrationAdapter`
/// (IdentityLocalDataBackend.swift) is where the two get translated.
public enum OwnershipMigrationOutcome: Sendable, Equatable {
    case succeeded
    case deferred
    case skipped
}

/// Abstracts `ReloraData.GuestMigration`'s durable ownership-migration
/// machinery for `IdentityController`. `ReloraServicesTests` depends on
/// `ReloraCore` but not `ReloraData` (see `Package.swift`), so this
/// protocol — expressed only in terms of `Identity` and
/// `OwnershipMigrationOutcome`, both native to this module — is what lets
/// `IdentityController` delegate to the real retry/backoff/marker logic in
/// production while a test conforms a plain fake directly, with no
/// ReloraData dependency either way. `OwnershipMigrationAdapter`
/// (IdentityLocalDataBackend.swift) wraps a real `GuestMigration` to
/// conform.
public protocol OwnershipMigrating: Sendable {
    func hasPending() throws -> Bool
    func runMigration(fromUserID: String, toUserID: String, source: String) async -> OwnershipMigrationOutcome
    /// Retries a migration left incomplete by an earlier session, claiming
    /// it for `currentIdentity` if that identity is allowed to (only an
    /// account may — see `GuestMigration.canClaimStrandedRows`).
    func resumePendingMigrationIfAny(currentIdentity: Identity, source: String) async -> (outcome: OwnershipMigrationOutcome, fromUserID: String?, toUserID: String?)
    /// Deletes every local content and usage row and resets sync state.
    /// Ports `clearLocalData` (dataControls.ts) via
    /// `GuestMigration.clearAllLocalData()`.
    func clearAllLocalData() throws
}

/// Abstracts the one durable key `IdentityController` needs — the stored
/// local-guest id (`local_anonymous_user_id`) — for the same reason as
/// `OwnershipMigrating`: no direct `ReloraData.AppSettingsStore` reference,
/// so the test target needs no ReloraData dependency.
/// `AppSettingsGuestIDStore` (IdentityLocalDataBackend.swift) wraps the
/// real store to conform.
public protocol LocalGuestIDStore: Sendable {
    func read() throws -> String?
    func write(_ userID: String?) throws
}

// MARK: - AuthBackend

/// A Supabase session, as `IdentityController` needs it. Abstracts over
/// supabase-swift's `Session`/`User` so `IdentityController` and its tests
/// depend only on this module, not on the `Auth` package directly.
public struct AuthUser: Sendable, Equatable {
    public var id: String
    public var email: String?
    public var isAnonymous: Bool

    public init(id: String, email: String? = nil, isAnonymous: Bool = false) {
        self.id = id
        self.email = email
        self.isAnonymous = isAnonymous
    }
}

public struct AuthSession: Sendable, Equatable {
    public var user: AuthUser
    public var accessToken: String
    public var refreshToken: String

    public init(user: AuthUser, accessToken: String, refreshToken: String) {
        self.user = user
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

/// Abstracts Supabase auth for `IdentityController`, scoped to the surface
/// the RN flows this ports actually call (`supabase.auth.*` calls
/// scattered across authState.ts, authLogic.ts, and authDeepLink.ts). A
/// fake conforms directly for tests; `SupabaseAuthBackend`
/// (IdentitySupabaseBackend.swift) wraps supabase-swift's `AuthClient` for
/// production use.
public protocol AuthBackend: Sendable {
    /// The current session, refreshed first if the underlying client does
    /// that implicitly; `nil` when there is none. Mirrors
    /// `supabase.auth.getSession()`.
    func currentSession() async throws -> AuthSession?
    /// Mirrors `supabase.auth.signInAnonymously()`.
    func signInAnonymously() async throws -> AuthSession
    /// Mirrors `supabase.auth.signUp({ email, password })`. Returns `nil`
    /// when Supabase accepted the sign-up but did not open a session (e.g.
    /// email confirmation is required before one exists).
    func signUp(email: String, password: String) async throws -> AuthSession?
    /// Mirrors `supabase.auth.signInWithPassword({ email, password })`.
    func signIn(email: String, password: String) async throws -> AuthSession
    /// Mirrors `supabase.auth.signOut()`.
    func signOut() async throws
    /// Mirrors `supabase.auth.resetPasswordForEmail(email, { redirectTo })`.
    func resetPassword(email: String, redirectTo: URL?) async throws
    /// Mirrors `supabase.auth.updateUser({ password: newPassword })`,
    /// called on the session a password-recovery deep link opened.
    func updatePassword(_ newPassword: String) async throws
    /// Establishes a session from an auth callback URL — handles both the
    /// PKCE `code` exchange and the implicit-flow access/refresh-token
    /// pair. Mirrors the two branches of `applyAuthDeepLink` in
    /// authDeepLink.ts (`exchangeCodeForSession` / `setSession`), unified
    /// into the one call supabase-swift's `AuthClient.session(from:)`
    /// already provides.
    func sessionFromURL(_ url: URL) async throws -> AuthSession
}
