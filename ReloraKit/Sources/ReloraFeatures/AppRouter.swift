import Foundation
import Observation
import ReloraServices

// MARK: - Root gating

/// What the app shows at its root.
public enum RootDestination: Equatable, Sendable {
    /// Identity has not been restored yet. A blank warm screen, not a spinner —
    /// bootstrap is a database read and a keychain read, and a spinner that
    /// flashes for 40ms is worse than nothing.
    case launching
    /// First run. Onboarding owns the screen (M10; a placeholder until then).
    case onboarding
    /// The hub. Renders signed-out when identity is `.unresolved`.
    case home
}

/// The root decision, kept pure so the one rule that matters can be tested
/// without a view.
///
/// **The rule that matters:** `.unresolved` does not mean "new user". After
/// sign-out, identity returns to `.unresolved` while `onboardingCompleted`
/// stays true, and RN restarted onboarding from there — the sign-out bug this
/// rebuild exists to fix. Onboarding is gated on the *flag*, never on identity
/// alone. See `docs/milestone-notes.md`, "Identity rulings from the M3 review".
///
/// **M10 revision:** the flag is now the gate for `.localGuest`/`.anonymous`
/// too, not only `.unresolved`. Onboarding's own LetsTryIt step mints a
/// local guest identity mid-flow, before the flag is set — that is the
/// moment the tutorial example needs an owner — and GetStarted does the
/// same again for "Enter Relora"/"See your example". The pre-M10 rule
/// ("any resolved identity means Home") predates onboarding minting
/// identity of its own, and taken literally it tore the coordinator down the
/// instant the create-example action resolved a guest id, before LetsTryIt
/// could show its completed state or GetStarted could ever render. `.account`
/// keeps its own unconditional branch: a real, authenticated sign-in (the one
/// GetStarted's "Create account / Sign in" button can produce) always means
/// Home, flag or no flag — nothing legitimate signs a fresh account in and
/// expects to see onboarding again.
public enum RootGate {
    public static func destination(
        identity: Identity,
        isBootstrapped: Bool,
        onboardingCompleted: Bool
    ) -> RootDestination {
        guard isBootstrapped else {
            return .launching
        }
        if case .account = identity {
            return .home
        }
        return onboardingCompleted ? .home : .onboarding
    }
}

// MARK: - Deep links

/// A link the app knows how to act on.
public enum ReloraDeepLink: Equatable, Sendable {
    case contact(id: String)
    /// An auth callback. Classification only — establishing the session belongs
    /// to `IdentityController.handleAuthDeepLink`, which owns the tokens.
    case auth(isPasswordRecovery: Bool)
    case unknown

    /// Splits a URL into "the router handles this" and "identity handles this".
    ///
    /// Auth links are checked first because they are the ones that carry
    /// credentials in the fragment; anything that looks like one must reach
    /// `IdentityController` rather than being parsed here.
    public static func classify(_ url: URL) -> ReloraDeepLink {
        if case .authLink(let isPasswordRecovery) = AuthDeepLink.classify(url) {
            return .auth(isPasswordRecovery: isPasswordRecovery)
        }

        // `relora://contact/<id>` parses as host "contact", path "/<id>".
        // A trailing slash or a `relora:///contact/<id>` spelling both survive
        // by filtering the components rather than indexing them.
        let components = ([url.host] + url.pathComponents)
            .compactMap { $0 }
            .filter { $0 != "/" && !$0.isEmpty }

        if components.count >= 2, components[0] == "contact" {
            return .contact(id: components[1])
        }
        return .unknown
    }
}

// MARK: - Router

/// Where the app can be, and how it gets there.
///
/// One `NavigationStack` path plus one sheet slot. A single sheet slot is a
/// constraint, not an oversight: two sheets open at once is a SwiftUI bug
/// generator, and there is no place in this product where a second modal over a
/// modal is the right answer.
@MainActor
@Observable
public final class AppRouter {

    /// Pushed destinations. Home is the stack's root and so is not a case.
    public enum Route: Hashable {
        case contactDetail(contactID: String)
        /// M8. What Home's bell opens.
        case reminders
    }

    /// What a contact form is for.
    public enum ContactEditTarget: Hashable {
        case new(prefill: ContactDraft?)
        case existing(contactID: String)
    }

    /// Why the paywall opened.
    ///
    /// RN's paywall route takes `{ reason, source }` — two strings that always
    /// move together (`getBlockedPaywallParams` in
    /// `VoiceCaptureComposerScreen.tsx` picks both from one condition). Only
    /// the reason travels here; M9 maps it to the analytics source when it
    /// builds the real paywall, because a `source` the router carries but
    /// nothing reads is a second thing to keep in step for no gain.
    public enum PaywallReason: String, Hashable, Sendable {
        /// Free plan, all five lifetime notes used. RN source: `hard_limit`.
        case freeLimitReached = "free_limit_reached"
        /// Plus plan, this month's hundred used. RN source: `plus_quota`.
        case plusQuotaReached = "plus_quota_reached"
        /// A recording hit the plan's length cap and the user asked to see
        /// plans. RN source: `duration_limit`.
        case durationLimit = "duration_limit"
        /// Opened by choice, not by a limit — RN's Settings upgrade entry
        /// passes this. Carries its own copy ("Upgrade when you're ready
        /// for more"), distinct from the free-limit fallback; M10's
        /// Settings screen is the caller.
        case manual
    }

    /// Modal destinations.
    ///
    /// `contactEdit` is here rather than in `Route` — a deviation from the
    /// milestone brief's route list, taken because the same brief asks for
    /// Cancel/Save in the toolbar. A pushed screen with a Cancel button fights
    /// the back button it sits next to; Apple's own Contacts presents both new
    /// and edit modally for exactly this reason.
    public enum Sheet: Identifiable, Hashable {
        case contactEdit(ContactEditTarget)
        case contactPicker
        case contactImport
        case settings
        /// M6.
        case voiceComposer(contactID: String?)
        /// M9.
        case paywall(reason: PaywallReason?)
        /// M9.
        case authGate
        /// M10.
        case setNewPassword
        /// M8b. `contactName` is display-only (the form's footer text) —
        /// looked up fresh by the view model at save time, never trusted
        /// stale across the sheet's lifetime.
        case addReminder(contactID: String, contactName: String)

        public var id: Self { self }
    }

    public var path: [Route] = []
    public var sheet: Sheet?

    /// What `.authGate` renders. Read alongside the bare `.authGate` case
    /// rather than as an associated value on it (M10) — `Sheet.authGate`
    /// carries no payload because `HomeView`, `RemindersView`, and two call
    /// sites in this file all present it bare today; giving the case a
    /// mandatory associated value would have broken every one of those
    /// call sites, two of which (`Home/`, `Reminders/`) this milestone does
    /// not own. Defaults to `.settings`, and `presentAuthGate` is the only
    /// way to set anything else — every existing `router.present(.authGate)`
    /// call site keeps compiling and keeps rendering the generic copy it
    /// always has. See the M10 report.
    public var authGateContext = AuthGateContext.settings

    /// A notification-tap deep link that arrived before the app could
    /// navigate — bootstrap not finished, most likely a cold launch. Single
    /// slot, not persisted: ports the queued-replay behavior in RN's
    /// `notificationLinking.ts`, which holds at most one pending URL and
    /// replays it once, discarding it either way rather than retrying
    /// forever.
    public private(set) var pendingDeepLinkURL: URL?

    public init() {}

    // MARK: Navigation

    public func openContact(_ contactID: String) {
        path.append(.contactDetail(contactID: contactID))
    }

    public func openReminders() {
        path.append(.reminders)
    }

    public func present(_ sheet: Sheet) {
        self.sheet = sheet
    }

    /// Presents `.authGate` with a specific context — the voice composer's
    /// "sign in to finish this note" copy is the one call site that needs
    /// this today. Every other opener keeps calling
    /// `router.present(.authGate)`, which renders `context`'s default.
    public func presentAuthGate(_ context: AuthGateContext = .settings) {
        authGateContext = context
        sheet = .authGate
    }

    public func dismissSheet() {
        sheet = nil
        // Cleared unconditionally rather than only for `.authGate` — the
        // property is only ever read while that sheet is showing, so
        // resetting it here just means a later bare `.authGate` never
        // inherits a stale voice-capture context from an earlier
        // presentation.
        authGateContext = .settings
    }

    public func popToRoot() {
        path.removeAll()
    }

    /// Navigates after a contact is created or picked: back to the root, then
    /// into the contact. The user asked for that person, so that person is where
    /// they should end up — not on a Home they have to search again.
    public func showNewlySavedContact(_ contactID: String) {
        sheet = nil
        path = [.contactDetail(contactID: contactID)]
    }

    // MARK: Deep links

    /// Acts on a link the app was opened with.
    ///
    /// Auth links are handed to `IdentityController`, which owns the tokens; the
    /// router only decides what to show once it reports back. A password
    /// recovery link opens the set-new-password sheet — and opens it even on
    /// failure, because a user who tapped a reset link and lands silently on
    /// Home has no way to tell whether anything happened. `SetNewPasswordView`
    /// (M10) reads `passwordRecoveryStatus` and says which it was.
    @discardableResult
    public func handle(
        _ url: URL,
        identity: IdentityController
    ) async -> ReloraDeepLink {
        let link = ReloraDeepLink.classify(url)

        switch link {
        case .contact(let id):
            sheet = nil
            path = [.contactDetail(contactID: id)]
        case .auth(let isPasswordRecovery):
            _ = await identity.handleAuthDeepLink(url)
            if isPasswordRecovery {
                sheet = .setNewPassword
            }
        case .unknown:
            break
        }

        return link
    }

    /// Entry point for a tapped reminder notification. Bootstrap is usually
    /// already finished by the time someone taps a notification — the app
    /// had to be running earlier to have scheduled it — but a cold launch
    /// racing the tap is the one case that is not: `isBootstrapped` is still
    /// false while `identity.bootstrap()` is in flight. This holds the URL
    /// rather than handling it against an identity that has not settled yet,
    /// and `AppBootstrap.start()` calls `replayPendingDeepLink` right after
    /// bootstrap finishes.
    public func handleNotificationTap(_ url: URL, identity: IdentityController) async {
        guard identity.isBootstrapped else {
            pendingDeepLinkURL = url
            return
        }
        await handle(url, identity: identity)
    }

    /// Replays and clears a queued notification-tap URL, if there is one and
    /// the app can navigate now. A no-op otherwise, so it is safe to call
    /// unconditionally after every point that might have just made
    /// navigation possible.
    @discardableResult
    public func replayPendingDeepLink(identity: IdentityController) async -> ReloraDeepLink? {
        guard identity.isBootstrapped, let url = pendingDeepLinkURL else { return nil }
        pendingDeepLinkURL = nil
        return await handle(url, identity: identity)
    }
}
