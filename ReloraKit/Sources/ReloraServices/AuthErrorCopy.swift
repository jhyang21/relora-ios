import Foundation

/// What the user reads when an auth call fails, and what the screen can offer
/// them next.
///
/// Before this, every failure on the auth screen reached the user as
/// `error.localizedDescription` from supabase-swift: `invalid_credentials`,
/// `AuthApiError`, `Email address ... is invalid`. Those strings are written
/// for whoever is reading the logs. They tell a person nothing, and two of
/// them read as an accusation.
///
/// **Why the matching runs on text.** This repo is authored on Windows and
/// cannot compile against the Supabase SDK, and `IdentitySupabaseBackend.swift`
/// says in its own banner that the error enum is the least trustworthy surface
/// in it. Keying on the lowercased description compiles whatever shape that
/// enum turns out to have; keying on the enum would not compile at all if it
/// has drifted. Every unmatched error still lands on a safe generic message,
/// so the failure mode of a wrong guess is a vaguer sentence, never a crash
/// and never a leak.
public struct AuthErrorCopy: Equatable, Sendable {

    /// The one thing worth offering after this particular failure. `nil` means
    /// there is nothing useful to suggest and the user should just try again.
    ///
    /// This names the way out, not a button. The screen decides whether to draw
    /// one: `AuthView` skips `.forgotPassword`, because in sign-in mode that
    /// link is already on screen and a second copy of it beside the error reads
    /// as a stutter rather than an offer.
    public enum Recovery: Equatable, Sendable {
        /// "Forgot password?" — the password is wrong and they may not have it.
        case forgotPassword
        /// "Sign in instead" — the address already has an account.
        case switchToSignIn
    }

    /// Which call failed. The same server error means different things
    /// depending on what the user was trying to do, and one of those
    /// differences is a privacy decision — see `passwordReset` below.
    public enum Intent: Equatable, Sendable {
        case createAccount
        case signIn
        case passwordReset
        case updatePassword
        case appleSignIn
    }

    public let message: String
    public let recovery: Recovery?

    public init(message: String, recovery: Recovery? = nil) {
        self.message = message
        self.recovery = recovery
    }

    // MARK: Mapping

    public static func forError(_ error: Error, intent: Intent) -> AuthErrorCopy {
        let text = searchText(for: error)

        if isOffline(error) || matches(text, Signal.offline) {
            return AuthErrorCopy(message: Message.offline)
        }

        if matches(text, Signal.rateLimited) {
            return AuthErrorCopy(message: Message.rateLimited)
        }

        // A reset request never says whether the address is known. Telling a
        // stranger which addresses have accounts is the one thing this screen
        // must not do, and the success copy is already written so that it does
        // not have to. Only the two failures that are about the request itself
        // get their own wording.
        if intent == .passwordReset {
            return AuthErrorCopy(message: Message.generic)
        }

        if matches(text, Signal.weakPassword) {
            return AuthErrorCopy(message: PasswordRule.hint)
        }

        if matches(text, Signal.alreadyRegistered) {
            return AuthErrorCopy(message: Message.alreadyRegistered, recovery: .switchToSignIn)
        }

        if matches(text, Signal.emailNotConfirmed) {
            return AuthErrorCopy(message: Message.emailNotConfirmed)
        }

        if matches(text, Signal.invalidEmail) {
            return AuthErrorCopy(message: Message.invalidEmail)
        }

        if matches(text, Signal.badCredentials) {
            switch intent {
            case .signIn:
                return AuthErrorCopy(message: Message.badCredentials, recovery: .forgotPassword)
            default:
                // `user not found` is in this bucket, and on any other intent
                // repeating it would confirm that an address has no account.
                return AuthErrorCopy(message: Message.generic)
            }
        }

        return AuthErrorCopy(message: Message.generic)
    }

    // MARK: Copy

    /// Every sentence a user can be shown after a failed auth call.
    ///
    /// None of them blames the person reading it, and none of them repeats a
    /// server string. "That email or password does not match" is deliberately
    /// about the pair, not about either half: naming which one was wrong would
    /// tell anyone with an email address whether it has an account here.
    public enum Message {
        public static let badCredentials = "That email or password does not match."
        public static let alreadyRegistered = "That email already has an account."
        public static let emailNotConfirmed = "Confirm your email first. Check your inbox for the link."
        public static let invalidEmail = "That email address does not look right. Check it and try again."
        public static let rateLimited = "Too many attempts. Wait a minute and try again."
        public static let offline = "You are offline. Check your connection and try again."
        public static let generic = "Something went wrong. Try again."
    }

    // MARK: Matching

    /// The substrings each cause is recognised by, lowercased.
    ///
    /// Both the GoTrue error code (`invalid_credentials`) and the human
    /// sentence it ships with (`Invalid login credentials`) are listed for
    /// every case, because which of the two reaches `localizedDescription`
    /// depends on the SDK version.
    private enum Signal {
        static let badCredentials = [
            "invalid_credentials",
            "invalid login credentials",
            "invalid_grant",
            "user_not_found",
            "user not found"
        ]
        static let alreadyRegistered = [
            "already registered",
            "already been registered",
            "user_already_exists",
            "email_exists",
            "duplicate key"
        ]
        static let weakPassword = [
            "weak_password",
            "weak password",
            "password should be at least",
            "password should contain"
        ]
        static let emailNotConfirmed = [
            "email_not_confirmed",
            "email not confirmed",
            "not confirmed"
        ]
        static let invalidEmail = [
            "email_address_invalid",
            "invalid email",
            "unable to validate email"
        ]
        /// The text half of the network check. A `URLError` the SDK has
        /// wrapped in an error of its own no longer carries
        /// `NSURLErrorDomain`, and its sentence is the only thing left to
        /// recognise it by.
        static let offline = [
            "offline",
            "the internet connection appears to be offline",
            "network connection was lost",
            "could not connect to the server",
            "a server with the specified hostname could not be found"
        ]
        static let rateLimited = [
            "rate limit",
            "rate_limit",
            "too many requests",
            "over_email_send_rate_limit",
            "429"
        ]
    }

    private static func matches(_ text: String, _ signals: [String]) -> Bool {
        signals.contains { text.contains($0) }
    }

    /// Both the localized description and the raw case name, joined. The SDK
    /// puts the useful part in one or the other depending on how the error was
    /// built, and searching both costs nothing.
    private static func searchText(for error: Error) -> String {
        "\(error.localizedDescription) \(String(describing: error))".lowercased()
    }

    /// Network failures come through as `URLError` whatever the auth SDK does
    /// with them, so this is the one branch that keys on a type rather than on
    /// text.
    private static func isOffline(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }

        let offlineCodes: Set<Int> = [
            URLError.notConnectedToInternet.rawValue,
            URLError.networkConnectionLost.rawValue,
            URLError.timedOut.rawValue,
            URLError.cannotFindHost.rawValue,
            URLError.cannotConnectToHost.rawValue,
            URLError.dnsLookupFailed.rawValue,
            URLError.dataNotAllowed.rawValue,
            URLError.internationalRoamingOff.rawValue,
            URLError.secureConnectionFailed.rawValue
        ]
        return offlineCodes.contains(nsError.code)
    }
}
