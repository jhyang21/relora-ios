import Auth
import Foundation
import ReloraCore

/// Wraps supabase-swift's `Auth` product (`AuthClient`) to satisfy
/// `AuthBackend` for production use. Test code should conform a fake to
/// `AuthBackend` directly instead of using this type.
///
/// ⚠️ UNVERIFIED — this package only builds on macOS, and this file was
/// written on Windows with no Swift toolchain to compile against. Every
/// `AuthClient`/`Session`/`User` member referenced below is a best-effort
/// name from memory of the supabase-swift 2.x API, not something this
/// change has compiled or run. supabase-swift has moved method names and
/// signatures across 2.x minor versions before, so treat this whole file
/// as a draft to correct against whatever version `Package.resolved`
/// actually pins on the first macOS build — most likely to have drifted,
/// roughly most to least likely:
///   - `AuthClient.init(url:headers:...)`'s exact parameter list
///   - `client.session` as a throwing async property (vs. a differently
///     named method) for "current session, refreshed if needed"
///   - `signUp(email:password:)`'s return type (`AuthResponse`, assumed
///     to carry an optional `session` — confirm the property name)
///   - `update(user:)` vs. `updateUser(...)` for a password change, and
///     `UserAttributes`'s exact initializer
///   - `resetPasswordForEmail(_:redirectTo:)` vs. `resetPassword(...)`
///   - `session(from:)` vs. some other name for the deep-link case
///   - whether `Session.user.id` is `UUID` (assumed below, mapped via
///     `.uuidString`) or already `String`
public final class SupabaseAuthBackend: AuthBackend {
    private let client: AuthClient

    /// Builds a client from a project URL and its public API key, the way
    /// every other `ReloraServices` type reads `BackendConfig`.
    public init(config: BackendConfig) {
        self.client = AuthClient(
            url: config.supabaseURL.appendingPathComponent("auth/v1"),
            headers: ["apikey": config.anonKey]
        )
    }

    /// For a caller that already owns a configured `AuthClient` — e.g.
    /// one shared with a full `SupabaseClient` constructed elsewhere.
    public init(client: AuthClient) {
        self.client = client
    }

    public func currentSession() async throws -> AuthSession? {
        do {
            return Self.map(try await client.session)
        } catch {
            // supabase-swift throws when there is no session to return
            // rather than returning nil — this backend's contract is the
            // reverse (nil means "none"), so any failure here reads as
            // "no current session" rather than propagating.
            return nil
        }
    }

    public func signInAnonymously() async throws -> AuthSession {
        Self.map(try await client.signInAnonymously())
    }

    public func signUp(email: String, password: String) async throws -> AuthSession? {
        let response = try await client.signUp(email: email, password: password)
        guard let session = response.session else { return nil }
        return Self.map(session)
    }

    public func signIn(email: String, password: String) async throws -> AuthSession {
        Self.map(try await client.signIn(email: email, password: password))
    }

    public func signOut() async throws {
        try await client.signOut()
    }

    public func resetPassword(email: String, redirectTo: URL?) async throws {
        try await client.resetPasswordForEmail(email, redirectTo: redirectTo)
    }

    public func updatePassword(_ newPassword: String) async throws {
        _ = try await client.update(user: UserAttributes(password: newPassword))
    }

    public func sessionFromURL(_ url: URL) async throws -> AuthSession {
        Self.map(try await client.session(from: url))
    }

    private static func map(_ session: Session) -> AuthSession {
        AuthSession(
            user: AuthUser(
                // Lowercased: Foundation's `uuidString` is uppercase, but
                // the server (and every row it returns) spells user ids
                // lowercase. Local ownership scoping compares these as
                // strings — an uppercase id would silently fork every
                // `WHERE user_id = ?` from the rows sync pulls down.
                id: session.user.id.uuidString.lowercased(),
                email: session.user.email,
                isAnonymous: session.user.isAnonymous
            ),
            accessToken: session.accessToken,
            refreshToken: session.refreshToken
        )
    }
}
