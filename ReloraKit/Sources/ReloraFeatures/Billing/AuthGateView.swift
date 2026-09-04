import SwiftUI
import ReloraDesign
import ReloraServices

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
    case settings
}

public struct AuthGateContext: Equatable, Sendable {
    public var action: AuthGateAction
    public var source: AuthGateSource

    public init(action: AuthGateAction, source: AuthGateSource) {
        self.action = action
        self.source = source
    }

    /// The plain settings-driven sign-in, and `presentAuthGate`'s default —
    /// no purchase or restore to link. Callers with a richer origin (voice
    /// capture, restore) pass their own context instead.
    public static let settings = AuthGateContext(action: .signIn, source: .settings)
}

/// Ports `AuthGateScreen.tsx`: email/password sign-up, sign-in, and forgot
/// password, in one form. Used two ways — as the sheet `PaywallView`
/// presents when a guest chooses a plan or taps Restore, and as `RootView`'s
/// standalone `.authGate` sheet (`AuthGateContext.settings`) for every other
/// sign-in entry point.
///
/// RN's telemetry `track(...)` calls on each submit have no native
/// equivalent — this build has no analytics layer — so they are simply
/// omitted rather than stubbed. Noted as an intentional omission in the M9
/// report.
public struct AuthGateView: View {
    @Environment(\.dismiss) private var dismiss

    private let context: AuthGateContext
    private let identity: IdentityController
    private let toasts: ReloraToastCenter

    @State private var email = ""
    @State private var password = ""
    @State private var confirmationEmail: String?
    @State private var resetEmail: String?
    @State private var loadingAction: LoadingAction?

    private enum LoadingAction: Equatable {
        case signUp
        case signIn
        case reset
    }

    public init(context: AuthGateContext, identity: IdentityController, toasts: ReloraToastCenter) {
        self.context = context
        self.identity = identity
        self.toasts = toasts
    }

    /// Mirrors `buildAuthGateCopy(params)`.
    private var copy: (title: String, subtitle: String) {
        switch context.action {
        case .purchase, .restore:
            return (
                "Save your notes and access them anywhere",
                "Create your account or sign in to back up your notes and link your subscription."
            )
        case .signIn:
            if context.source == .voiceCapture {
                return (
                    "Sign in to finish this note",
                    "Your recording is still here. Sign in and we will pick up right where you left off."
                )
            }
            return (
                "Create or access your account",
                "Use email and password to create your account or sign in on this device."
            )
        }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ReloraSpacing.lg) {
                    VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
                        Text(copy.title)
                            .font(ReloraFont.title)
                            .foregroundStyle(ReloraColor.ink)
                        Text(copy.subtitle)
                            .font(ReloraFont.body)
                            .foregroundStyle(ReloraColor.mutedInk)
                    }

                    if let confirmationEmail {
                        noticeCard(
                            title: "Confirm your email",
                            body: "We sent a confirmation link to \(confirmationEmail). Open it on this device to finish creating your account."
                        )
                    }

                    if let resetEmail {
                        noticeCard(
                            title: "Check your email",
                            body: "If \(resetEmail) has a Relora account, we sent a password reset link to it. Open it on this device to set a new password."
                        )
                    }

                    ReloraCard {
                        VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
                            TextField("Email", text: $email)
                                .textContentType(.username)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityLabel("Email")

                            SecureField("Password", text: $password)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityLabel("Password")

                            Text(PasswordRule.hint)
                                .font(ReloraFont.footnote)
                                .foregroundStyle(ReloraColor.mutedInk)

                            Button {
                                Task { await onSignUp() }
                            } label: {
                                Text(loadingAction == .signUp ? "Creating..." : "Create account")
                            }
                            .buttonStyle(.reloraPrimary)
                            .disabled(loadingAction != nil)
                            // Names stay put while the visible text reports
                            // progress, so neither button appears to rename
                            // itself the moment it is pressed.
                            .accessibilityLabel("Create account")

                            Button {
                                Task { await onSignIn() }
                            } label: {
                                Text(loadingAction == .signIn ? "Signing in..." : "Sign in")
                            }
                            .buttonStyle(.reloraSecondary)
                            .disabled(loadingAction != nil)
                            .accessibilityLabel("Sign in")

                            Button {
                                Task { await onForgotPassword() }
                            } label: {
                                // No underline: that is how the web marks a
                                // link and how iOS marks nothing. A tertiary
                                // action here is tinted text at a real tap
                                // size, which is also the 44pt target a line
                                // of footnote type does not have on its own.
                                Text(loadingAction == .reset ? "Sending..." : "Forgot password?")
                                    .font(ReloraFont.footnote)
                                    .foregroundStyle(ReloraColor.accentText)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(loadingAction != nil)
                            .accessibilityLabel("Forgot password")
                        }
                    }

                    Text("We only ask for an account when you need backup, sync, or a linked subscription.")
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)
                }
                .padding(.horizontal, ReloraLayout.screenHPadding)
                .padding(.vertical, ReloraSpacing.lg)
                .frame(maxWidth: ReloraLayout.contentMaxWidth)
            }
            .scrollContentBackground(.hidden)
            .background(ReloraColor.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func noticeCard(title: String, body: String) -> some View {
        ReloraCard(surface: ReloraColor.warmCard) {
            VStack(alignment: .leading, spacing: ReloraSpacing.xs) {
                Text(title)
                    .font(ReloraFont.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(ReloraColor.ink)
                Text(body)
                    .font(ReloraFont.footnote)
                    .foregroundStyle(ReloraColor.mutedInk)
            }
        }
    }

    // MARK: - Actions

    /// Mirrors `onPasswordSignUp`. `IdentityController.signUp` itself throws
    /// `SignUpError.didNotOpenASession` for the confirmation-required case
    /// (Supabase accepted the sign-up but opened no session) — that is the
    /// native equivalent of RN's `result.status === 'confirmation_required'`
    /// branch, not a failure to surface as an error toast.
    private func onSignUp() async {
        // Checked here, not only on the server: the server's rejection
        // costs a round trip and arrives as a raw auth-error string.
        if let failure = PasswordRule.validate(password) {
            toasts.showError(PasswordRule.title(for: failure), message: PasswordRule.hint)
            return
        }
        loadingAction = .signUp
        resetEmail = nil
        defer { loadingAction = nil }
        do {
            try await identity.signUp(email: email, password: password)
            // A session opened immediately (confirmation not required for
            // this project) — dismissing lets `PaywallView`'s
            // `onChange(of: identity.identity)` resume any pending purchase
            // or restore; for a bare sign-in-context gate this just closes
            // the sheet, matching `navigation.goBack()` after a completed
            // RN sign-up.
            dismiss()
        } catch IdentityController.SignUpError.didNotOpenASession {
            confirmationEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
            password = ""
        } catch {
            toasts.showError("Create account failed", message: error.localizedDescription)
        }
    }

    /// Mirrors `onPasswordSignIn`.
    private func onSignIn() async {
        loadingAction = .signIn
        confirmationEmail = nil
        resetEmail = nil
        defer { loadingAction = nil }
        do {
            try await identity.signIn(email: email, password: password)
            dismiss()
        } catch {
            toasts.showError("Sign in failed", message: error.localizedDescription)
        }
    }

    /// Mirrors `onForgotPassword`.
    private func onForgotPassword() async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            toasts.showError("Enter your email", message: "Enter your email above first, then request a reset link.")
            return
        }
        loadingAction = .reset
        confirmationEmail = nil
        defer { loadingAction = nil }
        do {
            try await identity.sendPasswordReset(email: trimmedEmail)
            resetEmail = trimmedEmail
        } catch {
            toasts.showError("Could not send reset email", message: error.localizedDescription)
        }
    }
}
