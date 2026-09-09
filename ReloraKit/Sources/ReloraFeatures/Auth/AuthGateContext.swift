import Foundation

/// Which of the two things the screen is doing.
///
/// The screen it replaced did both at once: one set of fields under two live
/// submit buttons, "Create account" filled and "Sign in" outlined. Nothing on
/// it said which one belonged to the person looking at it, so a returning user
/// had to notice that their action was the quieter button, and a mistap made
/// an account instead of opening one. A mode makes that a decision the caller
/// has already taken.
public enum AuthMode: Equatable, Hashable, Sendable {
    case createAccount
    case signIn

    /// The other one. There are exactly two, and every switch link toggles.
    public var opposite: AuthMode {
        self == .createAccount ? .signIn : .createAccount
    }
}

/// Why an account is being asked for, and where the ask came from. Mirrors
/// the `{action, source}` pair `buildAuthGateCopy` (authGateContent.ts)
/// switches on — RN derives `action` from route params built by
/// `buildPendingIntent`; here the caller states it directly.
public enum AuthGateAction: Equatable, Sendable {
    case purchase
    case restore
    case signIn
}

public enum AuthGateSource: Equatable, Sendable {
    case paywall
    /// Reachable since M10: `AppRouter.authGateContext` carries the context
    /// for the standalone `.authGate` sheet, and `RootView`'s voice-composer
    /// `onSignIn` passes `source: .voiceCapture` through it — matching RN's
    /// `source: 'voice_capture'` and its "Sign in to finish this note" copy.
    case voiceCapture
    /// The last step of onboarding. Added with the 2.6.0 redesign: this is the
    /// one entry point where the person has demonstrably never had an account,
    /// and `GetStartedStep` used to borrow `.settings` and get sign-in copy for
    /// it.
    case onboarding
    case settings
}

public struct AuthGateContext: Equatable, Sendable {
    public var action: AuthGateAction
    public var source: AuthGateSource
    /// Which mode the sheet opens in. Derived from the caller unless one is
    /// named, so no existing call site had to change to get the right one.
    public var initialMode: AuthMode

    public init(action: AuthGateAction, source: AuthGateSource, initialMode: AuthMode? = nil) {
        self.action = action
        self.source = source
        self.initialMode = initialMode ?? Self.defaultMode(action: action, source: source)
    }

    /// The plain settings-driven sign-in, and `presentAuthGate`'s default —
    /// no purchase or restore to link. Callers with a richer origin (voice
    /// capture, restore) pass their own context instead.
    public static let settings = AuthGateContext(action: .signIn, source: .settings)

    /// What the caller implies about who is holding the phone.
    ///
    /// Somebody who has reached a signed-out screen, a paused recording or
    /// Settings has had an account before; somebody finishing onboarding or
    /// buying a subscription as a guest has not. Either can switch in one tap,
    /// so the cost of guessing wrong is a tap, and the cost of not guessing is
    /// the screen this redesign exists to replace.
    private static func defaultMode(action: AuthGateAction, source: AuthGateSource) -> AuthMode {
        switch source {
        case .onboarding:
            return .createAccount
        case .paywall:
            // Buying or restoring from the paywall as a guest is a first
            // account far more often than not; the explicit "Sign in" action
            // is the exception and says so.
            return action == .signIn ? .signIn : .createAccount
        case .voiceCapture, .settings:
            return .signIn
        }
    }
}
