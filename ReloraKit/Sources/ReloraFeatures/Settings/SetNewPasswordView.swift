import SwiftUI
import ReloraDesign
import ReloraServices

/// Ports `SetNewPasswordScreen.tsx`. Reached only through
/// `AppRouter.handle`'s password-recovery deep-link branch — there is no
/// other way in, matching RN's own doc comment on the screen.
public struct SetNewPasswordView: View {
    @State private var viewModel: SetNewPasswordViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    private enum Field {
        case password, confirmPassword
    }

    public init(identity: IdentityController, toasts: ReloraToastCenter) {
        _viewModel = State(wrappedValue: SetNewPasswordViewModel(identity: identity, toasts: toasts))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ReloraSpacing.lg) {
                    VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
                        Text("Set a new password")
                            .font(ReloraFont.largeTitle)
                            .foregroundStyle(ReloraColor.ink)
                        Text("Choose a new password to finish resetting your account.")
                            .font(ReloraFont.body)
                            .foregroundStyle(ReloraColor.mutedInk)
                    }

                    if viewModel.recoveryLinkFailed {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("That reset link expired")
                                .font(ReloraFont.body)
                                .foregroundStyle(ReloraColor.danger)
                            Text("Request a new one from the sign-in screen.")
                                .font(ReloraFont.footnote)
                                .foregroundStyle(ReloraColor.mutedInk)
                        }
                        .padding(ReloraSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .reloraSurface(ReloraColor.card, radius: ReloraRadius.md)
                        .reloraBorder(ReloraColor.danger.opacity(0.4), radius: ReloraRadius.md)
                    }

                    VStack(alignment: .leading, spacing: ReloraSpacing.md) {
                        // `fill: background` rather than the component's
                        // default `card`: this form sits inside a card, and a
                        // white field on a white card is not a field.
                        ReloraSecureFormField(
                            "New password",
                            text: $viewModel.password,
                            focus: $focusedField,
                            equals: .password,
                            error: viewModel.passwordError,
                            fill: ReloraColor.background,
                            contentType: .newPassword,
                            submitLabel: .next,
                            onSubmit: { focusedField = .confirmPassword }
                        )

                        ReloraSecureFormField(
                            "Confirm new password",
                            text: $viewModel.confirmPassword,
                            focus: $focusedField,
                            equals: .confirmPassword,
                            error: viewModel.confirmError,
                            fill: ReloraColor.background,
                            contentType: .newPassword,
                            submitLabel: .done,
                            onSubmit: { handleSubmit() }
                        )

                        if viewModel.passwordError == nil {
                            Text(PasswordRule.hint)
                                .font(ReloraFont.footnote)
                                .foregroundStyle(ReloraColor.mutedInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let formError = viewModel.formError {
                            ReloraInlineError(formError)
                        }

                        Button {
                            handleSubmit()
                        } label: {
                            ZStack {
                                Text("Save password")
                                    .opacity(viewModel.isSubmitting ? 0 : 1)
                                if viewModel.isSubmitting {
                                    ProgressView()
                                        .tint(ReloraColor.onAccent)
                                }
                            }
                        }
                        .buttonStyle(.reloraPrimary)
                        .disabled(viewModel.isSubmitting)
                        .accessibilityLabel(viewModel.isSubmitting ? "Saving password" : "Save password")
                    }
                    .padding(ReloraSpacing.lg)
                    // `reloraSurface` rather than a drawn rectangle and a
                    // hand-written shadow: in dark mode the elevation has to
                    // come from the surface colour, and a black shadow on a
                    // near-black ground is a card nobody can see.
                    .reloraSurface(ReloraColor.card, radius: ReloraRadius.xl, shadow: .card)
                }
                .padding(.horizontal, ReloraLayout.screenHPadding)
                .padding(.vertical, ReloraSpacing.lg)
                .frame(maxWidth: ReloraLayout.contentMaxWidth)
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(maxWidth: .infinity)
            .background(ReloraColor.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Every other sheet in the app offers one, and this screen
                // needs it most: a user who arrives on an expired reset link
                // is told the link is dead and otherwise has nothing to press.
                // Leaving here runs the same `handleDisappear` a swipe down
                // already ran, so it takes no new path through the view model.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onDisappear { viewModel.handleDisappear() }
        .onChange(of: viewModel.password) { _, _ in viewModel.inputChanged() }
        .onChange(of: viewModel.confirmPassword) { _, _ in viewModel.inputChanged() }
    }

    private func handleSubmit() {
        focusedField = nil
        Task {
            if await viewModel.submit() {
                dismiss()
            }
        }
    }
}
