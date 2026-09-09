import Foundation

/// The wording the auth screen chooses between, in one place.
///
/// Not every string on the screen. Field labels, the placeholder and the close
/// button read the same in both modes and stay in `AuthView` next to the
/// control they name; what lives here is the copy that changes with the mode,
/// the context or a result.
///
/// Split out from the view for the same reason `SettingsCopy` is: the wording
/// is the part of this screen most likely to change, and it is the part a
/// reviewer can check without reading SwiftUI. It is also the part the tests
/// assert on.
///
/// Strings are literals, not a String Catalog. The app has no localization
/// anywhere, and adding a catalog for one screen would leave the other forty
/// hardcoded while implying they were not.
enum AuthCopy {

    // MARK: Headline

    /// Says which of the two things is happening, in the largest type on the
    /// screen. This is the whole fix for the old screen's central problem.
    static func headline(mode: AuthMode) -> String {
        switch mode {
        case .createAccount: return "Create your account"
        case .signIn: return "Welcome back"
        }
    }

    /// One line under the headline saying why an account is being asked for.
    ///
    /// Relora never asks for an account to let someone in — onboarding mints a
    /// local guest and real notes belong to it. The ask only appears at backup,
    /// sync and subscription, so the line names whichever of those brought the
    /// user here.
    static func supporting(context: AuthGateContext, mode: AuthMode) -> String {
        switch context.action {
        case .purchase, .restore:
            return "Your notes back up to this account, and your subscription links to it."
        case .signIn:
            switch context.source {
            case .voiceCapture:
                return "Your recording is still here. Sign in and we will pick up where you left off."
            case .onboarding:
                return "An account backs up your notes and puts them on every device you use."
            case .paywall, .settings:
                return mode == .createAccount
                    ? "An account backs up your notes and puts them on every device you use."
                    : "Sign in to reach your notes and your subscription on this device."
            }
        }
    }

    // MARK: Actions

    static func primaryButton(mode: AuthMode) -> String {
        switch mode {
        case .createAccount: return "Create account"
        case .signIn: return "Sign in"
        }
    }

    /// The label a screen reader hears while the button shows a spinner. The
    /// name stays put so the button does not appear to rename itself the
    /// moment it is pressed.
    static func primaryButtonInProgress(mode: AuthMode) -> String {
        switch mode {
        case .createAccount: return "Creating your account"
        case .signIn: return "Signing in"
        }
    }

    /// The switch at the foot of the form. The question is quiet, the verb is
    /// the link.
    static func switchPrompt(mode: AuthMode) -> (question: String, action: String) {
        switch mode {
        case .createAccount: return ("Already have an account?", "Sign in")
        case .signIn: return ("New to Relora?", "Create an account")
        }
    }

    static let forgotPassword = "Forgot password?"
    static let signInInstead = "Sign in instead"

    // MARK: Notices

    /// Shown only when the request actually succeeded. It says what was sent
    /// and where, and it does not say whether the address has an account —
    /// answering that would let anyone test addresses against this screen.
    static func resetSent(email: String) -> String {
        "If \(email) has a Relora account, a password reset link is on its way. Open it on this device to set a new password."
    }

    static func confirmationSent(email: String) -> String {
        "We sent a confirmation link to \(email). Open it on this device to finish creating your account."
    }

    static let resetSentTitle = "Check your email"
    static let confirmationSentTitle = "Confirm your email"
    /// The way out of a notice for somebody who mistyped the address they just
    /// sent mail to. Without it the notice is a dead end.
    static let useDifferentEmail = "Use a different email"

    // MARK: Validation

    static let emailMissing = "Enter your email address."
    static let emailMalformed = "That email address does not look right."
    static let passwordMissing = "Enter your password."

    // MARK: Disclosure

    /// Shown in create mode only, and worded as a statement of fact rather
    /// than a checkbox. Nothing here is pre-consented, nothing subscribes the
    /// user to anything, and no claim is made about how secure the service is.
    /// Markdown, so `Text` renders both links itself. The URLs are the ones
    /// Settings already links to (`SettingsLegal`), not new ones invented for
    /// this screen — one set of legal pages, one source for them.
    static let legalDisclosure = """
        By creating an account you agree to our \
        [Terms of Use](\(SettingsLegal.termsOfUseURL.absoluteString)) and \
        [Privacy Policy](\(SettingsLegal.privacyPolicyURL.absoluteString)).
        """

    /// What a screen reader hears instead. The markdown link syntax reads as
    /// punctuation, and the two labels are already reachable as links.
    static let legalDisclosureSpoken = "By creating an account you agree to our Terms of Use and Privacy Policy."

    // MARK: Footer

    /// Why the app is asking at all. It sat at the bottom of the old screen as
    /// an orphan; it is kept because it is true and reassuring, and because
    /// nothing else on the screen says the account is optional.
    static let reassurance = "We only ask for an account when you need backup, sync, or a linked subscription."
}
