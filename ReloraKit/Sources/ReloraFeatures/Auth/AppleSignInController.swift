import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import ReloraServices

/// Runs one Sign in with Apple attempt for `AuthView`.
///
/// Apple's flow is two callbacks with a secret in between: the request carries
/// a hashed nonce, and the token that comes back has to be redeemed with the
/// raw one. Keeping that pair here rather than in the view means a second
/// attempt mints a fresh nonce instead of replaying the last one.
///
/// ⚠️ UNVERIFIED on this machine — nothing here has been compiled. See
/// `docs/macos-build-checklist.md` for the `AuthenticationServices` names this
/// file assumes.
@MainActor
@Observable
final class AppleSignInController {
    private(set) var isSigningIn = false

    /// The failure to show under the button, already turned into a sentence a
    /// person can act on. A cancelled sheet leaves this nil: the user closed
    /// it on purpose, and telling them so is noise.
    private(set) var error: AuthErrorCopy?

    /// The raw nonce for the attempt in flight. Apple only ever sees its
    /// SHA-256; Supabase gets this value and checks the two agree, which is
    /// what stops an identity token lifted from another app being replayed
    /// here.
    private var currentNonce: String?

    private let identity: IdentityController

    init(identity: IdentityController) {
        self.identity = identity
    }

    func clearError() {
        error = nil
    }

    /// Fills in the request the button is about to send.
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        error = nil

        // Relora stores no name, so it asks for none. The address is the only
        // thing the account is keyed on, and Apple returns it inside the
        // identity token.
        request.requestedScopes = [.email]

        // A failed generator leaves the nonce unset rather than reaching for a
        // weaker source. `complete` then refuses the token it gets back, so
        // the attempt fails safely instead of losing its replay defence.
        currentNonce = Self.randomNonce()
        if let nonce = currentNonce {
            request.nonce = Self.sha256(nonce)
        }
    }

    /// Handles the button's result. Returns whether a session opened, so the
    /// caller can close the sheet.
    func complete(_ result: Result<ASAuthorization, Error>) async -> Bool {
        error = nil

        switch result {
        case .failure(let failure):
            // Backing out of Apple's sheet is a decision, not a fault.
            if let authError = failure as? ASAuthorizationError, authError.code == .canceled {
                return false
            }
            error = AuthErrorCopy.forError(failure, intent: .appleSignIn)
            return false

        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                let nonce = currentNonce
            else {
                error = AuthErrorCopy(message: AuthErrorCopy.Message.generic)
                return false
            }

            currentNonce = nil
            isSigningIn = true
            defer { isSigningIn = false }

            do {
                // Routed through `IdentityController`, never straight at the
                // backend: that is the call that migrates a guest's local
                // notes onto the new account id.
                try await identity.signInWithApple(idToken: idToken, nonce: nonce)
                return true
            } catch {
                self.error = AuthErrorCopy.forError(error, intent: .appleSignIn)
                return false
            }
        }
    }

    // MARK: Nonce

    /// A URL-safe random string, or `nil` if the system generator refuses.
    ///
    /// `SecRandomCopyBytes` rather than `Int.random`: this value is the replay
    /// defence, so it comes from the system's cryptographic generator or it
    /// does not come at all.
    private static func randomNonce() -> String? {
        // 64 characters, and 64 divides 256 exactly, so the modulo below
        // draws each one as often as any other.
        let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-.")
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return String(bytes.map { characters[Int($0) % characters.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
