import SwiftUI
import ReloraDesign
import ReloraServices

/// Create an account, or open the one you have. One screen, one mode at a
/// time, one submit button.
///
/// Replaces `Billing/AuthGateView.swift`, which offered both actions at once
/// and left the user to work out which of the two buttons was theirs. The
/// caller now states which it is (`AuthGateContext.initialMode`) and the
/// screen says so in its headline; the other one is a link at the foot of the
/// form that keeps whatever has already been typed.
///
/// Failures appear under the field they belong to and stay until the input
/// changes. Nothing on this screen reports an auth failure through a toast any
/// more: a four-second capsule at the bottom of the screen sits behind the
/// keyboard on a form, and it takes the message away while the user is still
/// reading it.
public struct AuthView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: AuthViewModel
    @FocusState private var focus: AuthViewModel.Field?

    public init(context: AuthGateContext, identity: IdentityController) {
        _viewModel = State(initialValue: AuthViewModel(context: context, identity: identity))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ReloraSpacing.lg) {
                    header

                    if let notice = viewModel.notice {
                        noticeCard(notice)
                    }

                    form

                    footer
                }
                .padding(.horizontal, ReloraLayout.screenHPadding)
                .padding(.vertical, ReloraSpacing.lg)
                .frame(maxWidth: ReloraLayout.contentMaxWidth)
            }
            // The keyboard covers the submit button on a 4.7-inch screen, and
            // the old screen gave no way to get rid of it without submitting.
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(ReloraColor.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onChange(of: viewModel.focusRequest) { _, requested in
            guard let requested else { return }
            focus = requested
            viewModel.clearFocusRequest()
        }
        .onChange(of: viewModel.email) { _, _ in viewModel.inputChanged() }
        .onChange(of: viewModel.password) { _, _ in viewModel.inputChanged() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
            Text(viewModel.headline)
                .font(ReloraFont.title)
                .foregroundStyle(ReloraColor.ink)
                .accessibilityAddTraits(.isHeader)
            Text(viewModel.supporting)
                .font(ReloraFont.body)
                .foregroundStyle(ReloraColor.mutedInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The headline is the answer to "what am I doing here", so it is
        // re-read whenever the mode changes rather than changing silently
        // under a screen reader.
        .id(viewModel.mode)
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: ReloraSpacing.md) {
            ReloraFormField(
                "Email",
                text: $viewModel.email,
                focus: $focus,
                equals: .email,
                error: viewModel.emailError,
                placeholder: "you@example.com",
                contentType: .username,
                keyboard: .emailAddress,
                submitLabel: .next,
                onSubmit: { focus = .password }
            )

            VStack(alignment: .leading, spacing: ReloraSpacing.xs) {
                ReloraSecureFormField(
                    "Password",
                    text: $viewModel.password,
                    focus: $focus,
                    equals: .password,
                    error: viewModel.passwordError,
                    // `.newPassword` is what offers the iOS strong-password
                    // generator and the save-to-Keychain prompt on a sign-up;
                    // the old screen used `.password` for both modes and got
                    // neither.
                    contentType: viewModel.mode == .createAccount ? .newPassword : .password,
                    submitLabel: .go,
                    onSubmit: { Task { await submit() } }
                )

                if viewModel.showsPasswordRule {
                    Text(PasswordRule.hint)
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let formError = viewModel.formError {
                VStack(alignment: .leading, spacing: 0) {
                    ReloraInlineError(formError.message)
                    if let recovery = formError.recovery, let label = recoveryLabel(recovery) {
                        Button(label) {
                            Task { await viewModel.applyRecovery(recovery) }
                        }
                        .buttonStyle(.reloraTertiary)
                        .disabled(viewModel.isBusy)
                    }
                }
            }

            submitButton

            if viewModel.mode == .signIn {
                Button(viewModel.isSendingReset ? "Sending..." : AuthCopy.forgotPassword) {
                    Task { await viewModel.sendPasswordReset() }
                }
                .buttonStyle(.reloraTertiary)
                .disabled(viewModel.isBusy)
                .accessibilityLabel("Forgot password")
                .frame(maxWidth: .infinity)
            }

            if viewModel.mode == .createAccount {
                legalDisclosure
            }
        }
    }

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            // The label stays put and a spinner sits over it, so the button
            // keeps its width and its name while it works. Swapping the text
            // for "Creating..." moves the layout and renames the control
            // under a screen reader.
            ZStack {
                Text(viewModel.primaryButtonTitle)
                    .opacity(viewModel.isSubmitting ? 0 : 1)
                if viewModel.isSubmitting {
                    ProgressView()
                        .tint(ReloraColor.onAccent)
                }
            }
        }
        .buttonStyle(.reloraPrimary)
        .disabled(viewModel.isBusy)
        .accessibilityLabel(
            viewModel.isSubmitting
                ? AuthCopy.primaryButtonInProgress(mode: viewModel.mode)
                : viewModel.primaryButtonTitle
        )
    }

    private var legalDisclosure: some View {
        Text(.init(AuthCopy.legalDisclosure))
            .font(ReloraFont.footnote)
            .foregroundStyle(ReloraColor.mutedInk)
            .tint(ReloraColor.accentText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(AuthCopy.legalDisclosureSpoken)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: ReloraSpacing.md) {
            switchRow

            Text(AuthCopy.reassurance)
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.mutedInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var switchRow: some View {
        let prompt = AuthCopy.switchPrompt(mode: viewModel.mode)
        return HStack(spacing: ReloraSpacing.xs) {
            Text(prompt.question)
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.mutedInk)
            Button(prompt.action) {
                viewModel.switchMode()
            }
            .buttonStyle(.reloraTertiary)
            .disabled(viewModel.isBusy)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Notice

    @ViewBuilder
    private func noticeCard(_ notice: AuthViewModel.Notice) -> some View {
        let content: (title: String, body: String) = {
            switch notice {
            case .confirmationSent(let email):
                return (AuthCopy.confirmationSentTitle, AuthCopy.confirmationSent(email: email))
            case .resetSent(let email):
                return (AuthCopy.resetSentTitle, AuthCopy.resetSent(email: email))
            }
        }()

        ReloraCard(surface: ReloraColor.warmCard) {
            VStack(alignment: .leading, spacing: ReloraSpacing.xs) {
                Text(content.title)
                    .font(ReloraFont.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(ReloraColor.ink)
                Text(content.body)
                    .font(ReloraFont.footnote)
                    .foregroundStyle(ReloraColor.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button(AuthCopy.useDifferentEmail) {
                    viewModel.dismissNotice()
                }
                .buttonStyle(.reloraTertiary)
            }
        }
    }

    // MARK: Actions

    private func recoveryLabel(_ recovery: AuthErrorCopy.Recovery) -> String? {
        switch recovery {
        case .switchToSignIn:
            return AuthCopy.signInInstead
        case .forgotPassword:
            // Already on screen as its own link in sign-in mode. Two identical
            // buttons stacked on each other is not an offer, it is a stutter.
            return nil
        }
    }

    private func submit() async {
        if await viewModel.submit() {
            dismiss()
        }
    }
}
