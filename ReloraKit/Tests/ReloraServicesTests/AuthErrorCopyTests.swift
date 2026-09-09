import Foundation
import Testing
@testable import ReloraServices

/// Stands in for whatever supabase-swift throws. The mapping keys on the
/// error's text rather than its type — see `AuthErrorCopy` for why — so a
/// plain error carrying the same sentence exercises the same path.
private struct StubAuthError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

private func copy(_ text: String, intent: AuthErrorCopy.Intent) -> AuthErrorCopy {
    AuthErrorCopy.forError(StubAuthError(text: text), intent: intent)
}

@Suite("AuthErrorCopy")
struct AuthErrorCopyTests {

    @Test("Wrong credentials read as a pair, and offer the reset", arguments: [
        "Invalid login credentials",
        "invalid_credentials",
        "invalid_grant"
    ])
    func badCredentials(text: String) {
        let result = copy(text, intent: .signIn)
        #expect(result.message == AuthErrorCopy.Message.badCredentials)
        #expect(result.recovery == .forgotPassword)
    }

    /// The enumeration rule. `user_not_found` on a sign-in is answered with
    /// the same sentence as a wrong password, so the screen never tells a
    /// stranger which addresses have accounts.
    @Test("A missing user is answered exactly like a wrong password")
    func missingUserIsIndistinguishable() {
        let missing = copy("User not found", intent: .signIn)
        let wrong = copy("Invalid login credentials", intent: .signIn)
        #expect(missing.message == wrong.message)
        #expect(missing.recovery == wrong.recovery)
    }

    @Test("A taken address offers the switch to sign in", arguments: [
        "User already registered",
        "email_exists",
        "duplicate key value violates unique constraint"
    ])
    func alreadyRegistered(text: String) {
        let result = copy(text, intent: .createAccount)
        #expect(result.message == AuthErrorCopy.Message.alreadyRegistered)
        #expect(result.recovery == .switchToSignIn)
    }

    @Test("A weak password repeats the app's own rule, not the server's")
    func weakPassword() {
        let result = copy("Password should be at least 6 characters", intent: .createAccount)
        #expect(result.message == PasswordRule.hint)
        #expect(result.recovery == nil)
    }

    @Test("An unconfirmed email says where to look")
    func emailNotConfirmed() {
        #expect(copy("Email not confirmed", intent: .signIn).message == AuthErrorCopy.Message.emailNotConfirmed)
    }

    @Test("Rate limiting asks for a wait, whatever the intent", arguments: [
        AuthErrorCopy.Intent.signIn,
        .createAccount,
        .passwordReset
    ])
    func rateLimited(intent: AuthErrorCopy.Intent) {
        #expect(copy("For security purposes, you can only request this after 60 seconds. rate limit", intent: intent).message
            == AuthErrorCopy.Message.rateLimited)
    }

    @Test("A network failure is named as one")
    func offline() {
        let error = URLError(.notConnectedToInternet)
        #expect(AuthErrorCopy.forError(error, intent: .signIn).message == AuthErrorCopy.Message.offline)
    }

    /// The same failure wrapped by the SDK loses `NSURLErrorDomain`, so the
    /// text half of the check has to catch it.
    @Test("A wrapped network failure is still named as one")
    func wrappedOffline() {
        let result = copy("The Internet connection appears to be offline.", intent: .signIn)
        #expect(result.message == AuthErrorCopy.Message.offline)
    }

    /// A reset request must not become an account-existence oracle, so every
    /// failure but rate limiting collapses to the generic sentence.
    @Test("A failed reset says nothing about the address", arguments: [
        "User not found",
        "Invalid login credentials",
        "User already registered",
        "Email not confirmed"
    ])
    func passwordResetLeaksNothing(text: String) {
        let result = copy(text, intent: .passwordReset)
        #expect(result.message == AuthErrorCopy.Message.generic)
        #expect(result.recovery == nil)
    }

    @Test("An unrecognised error falls back safely, and never quotes itself")
    func unknownError() {
        let result = copy("PostgrestError(code: 42501, detail: nil)", intent: .signIn)
        #expect(result.message == AuthErrorCopy.Message.generic)
        #expect(result.recovery == nil)
    }

    /// The whole point of the file: nothing a backend wrote reaches the user.
    @Test("No mapped message repeats a backend string")
    func neverEchoesTheBackend() {
        let raw = "AuthApiError(message: invalid_credentials, errorCode: 400)"
        for intent in [AuthErrorCopy.Intent.signIn, .createAccount, .passwordReset, .updatePassword, .appleSignIn] {
            let message = copy(raw, intent: intent).message
            #expect(!message.contains("invalid_credentials"))
            #expect(!message.contains("AuthApiError"))
        }
    }
}
