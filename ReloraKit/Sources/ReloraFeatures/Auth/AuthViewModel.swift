import Foundation
import Observation
import ReloraServices

/// Everything the auth screen decides, with no SwiftUI in it.
///
/// The screen this replaces put its rules inline: password validation next to
/// a toast call, trimming in one action and not in the other two, the
/// existing-account case handled as a generic failure. None of it could be
/// tested without a simulator. Here the rules are a plain observable object,
/// and `AuthViewModelTests` drives it against a fake auth backend.
///
/// It owns no navigation. `submit()` returns whether the sheet should close
/// and the view does the closing, because the same success has to resume a
/// pending purchase in one caller and simply dismiss in another.
@MainActor
@Observable
final class AuthViewModel {

    /// The two fields, and what `@FocusState` in the view is keyed on.
    enum Field: Hashable {
        case email
        case password
    }

    /// A success worth keeping on screen. Both are stated only after the call
    /// that produces them has actually succeeded — an app that says "check
    /// your email" for a request that failed sends the user to wait for
    /// nothing.
    enum Notice: Equatable {
        case confirmationSent(email: String)
        case resetSent(email: String)
    }

    private(set) var mode: AuthMode
    var email = ""
    var password = ""

    /// At most one of these three is set at a time, which is what keeps
    /// VoiceOver to a single announcement: field errors come from local
    /// validation, and `formError` is only reachable once validation has
    /// passed and left both field errors nil.
    private(set) var emailError: String?
    private(set) var passwordError: String?
    private(set) var formError: AuthErrorCopy?

    private(set) var notice: Notice?
    private(set) var isSubmitting = false
    private(set) var isSendingReset = false

    /// Where the keyboard should go next. The view applies it and clears it.
    /// Validation sets it so a rejected submit puts the caret in the field
    /// that has to change, rather than leaving the user to find it.
    private(set) var focusRequest: Field?

    let context: AuthGateContext
    private let identity: IdentityController

    init(context: AuthGateContext, identity: IdentityController) {
        self.context = context
        self.identity = identity
        self.mode = context.initialMode
    }

    // MARK: Derived copy

    var headline: String { AuthCopy.headline(mode: mode) }
    var supporting: String { AuthCopy.supporting(context: context, mode: mode) }
    var primaryButtonTitle: String { AuthCopy.primaryButton(mode: mode) }

    /// The password rule belongs to a password being chosen, not to one that
    /// already exists. Printing it while somebody signs in implies their
    /// current password has to satisfy it.
    var showsPasswordRule: Bool { mode == .createAccount && passwordError == nil }

    var isBusy: Bool { isSubmitting || isSendingReset }

    /// The address as it will be sent: the user's own text, minus whitespace
    /// they did not mean to type. Every call site uses this, including the
    /// two that did not before.
    var submittedEmail: String { EmailAddress.normalized(email) }

    // MARK: Mode

    /// Switches between creating and opening an account, keeping both fields.
    ///
    /// Keeping them is the point. The commonest failure on this screen is
    /// creating an account on an address that already has one, and the fix is
    /// one tap with the credentials already typed.
    func switchMode() {
        setMode(mode.opposite)
    }

    func setMode(_ newMode: AuthMode) {
        guard newMode != mode else { return }
        mode = newMode
        clearErrors()
        notice = nil
    }

    // MARK: Editing

    /// Called when either field changes. An error describes text that is no
    /// longer on screen the moment the user starts fixing it.
    func inputChanged() {
        guard emailError != nil || passwordError != nil || formError != nil else { return }
        clearErrors()
    }

    func clearFocusRequest() {
        focusRequest = nil
    }

    /// Puts the user back in the form with the caret in the email field —
    /// what "use a different email" means when the notice they are looking at
    /// names an address they mistyped.
    func dismissNotice() {
        notice = nil
        focusRequest = .email
    }

    // MARK: Submit

    /// Runs the mode's auth call. Returns `true` when the sheet should close.
    @discardableResult
    func submit() async -> Bool {
        guard !isBusy else { return false }
        clearErrors()
        notice = nil
        guard validate() else { return false }

        isSubmitting = true
        defer { isSubmitting = false }

        let address = submittedEmail

        switch mode {
        case .createAccount:
            do {
                try await identity.signUp(email: address, password: password)
                return true
            } catch IdentityController.SignUpError.didNotOpenASession {
                // Supabase accepted the sign-up but opened no session, which
                // means this project has email confirmation on. Not a failure
                // — the account exists and the link is out.
                notice = .confirmationSent(email: address)
                password = ""
                return false
            } catch {
                formError = AuthErrorCopy.forError(error, intent: .createAccount)
                return false
            }

        case .signIn:
            do {
                try await identity.signIn(email: address, password: password)
                return true
            } catch {
                formError = AuthErrorCopy.forError(error, intent: .signIn)
                return false
            }
        }
    }

    /// Sends a reset link to whatever is in the email field.
    ///
    /// The old screen refused and told the user to type their address above
    /// first, while their address was sitting above. This uses it, and only
    /// asks when the field really is empty.
    func sendPasswordReset() async {
        guard !isBusy else { return }
        clearErrors()
        notice = nil

        guard validateEmail() else { return }
        let address = submittedEmail

        isSendingReset = true
        defer { isSendingReset = false }

        do {
            try await identity.sendPasswordReset(email: address)
            notice = .resetSent(email: address)
        } catch {
            formError = AuthErrorCopy.forError(error, intent: .passwordReset)
        }
    }

    /// Acts on the offer attached to a failure. Only the switch needs doing
    /// here; the reset offer is the same call the always-visible link makes.
    func applyRecovery(_ recovery: AuthErrorCopy.Recovery) async {
        switch recovery {
        case .switchToSignIn:
            setMode(.signIn)
        case .forgotPassword:
            await sendPasswordReset()
        }
    }

    // MARK: Validation

    /// The first thing wrong, and only the first.
    ///
    /// Reporting every fault at once would put two inline errors on screen and
    /// have VoiceOver read them over each other. One at a time also matches
    /// `PasswordRule.validate`, which returns the first failing rule for the
    /// same reason: the hint under the field states all four anyway.
    private func validate() -> Bool {
        guard validateEmail() else { return false }
        guard !password.isEmpty else {
            passwordError = AuthCopy.passwordMissing
            focusRequest = .password
            return false
        }

        // Only when a password is being chosen. Checking it locally turns a
        // round trip and a raw server string into an immediate hint.
        if mode == .createAccount, PasswordRule.validate(password) != nil {
            passwordError = PasswordRule.hint
            focusRequest = .password
            return false
        }

        return true
    }

    /// The email half of validation, shared with `sendPasswordReset` — a
    /// reset needs a usable address for exactly the same reasons a submit
    /// does, and the two checks drifting apart is how the old screen ended up
    /// trimming on one call and not the others.
    private func validateEmail() -> Bool {
        let address = submittedEmail

        guard !address.isEmpty else {
            emailError = AuthCopy.emailMissing
            focusRequest = .email
            return false
        }
        guard EmailAddress.isValid(address) else {
            emailError = AuthCopy.emailMalformed
            focusRequest = .email
            return false
        }
        return true
    }

    private func clearErrors() {
        emailError = nil
        passwordError = nil
        formError = nil
    }
}
