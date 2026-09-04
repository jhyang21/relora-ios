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

                    VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
                        SecureField("New password", text: $viewModel.password)
                            .textContentType(.newPassword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(ReloraSpacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: ReloraRadius.sm, style: .continuous)
                                    .fill(ReloraColor.background)
                            )
                            .reloraBorder(radius: ReloraRadius.sm)
                            .focused($focusedField, equals: .password)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .confirmPassword }

                        SecureField("Confirm new password", text: $viewModel.confirmPassword)
                            .textContentType(.newPassword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(ReloraSpacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: ReloraRadius.sm, style: .continuous)
                                    .fill(ReloraColor.background)
                            )
                            .reloraBorder(radius: ReloraRadius.sm)
                            .focused($focusedField, equals: .confirmPassword)
                            .submitLabel(.done)
                            .onSubmit { handleSubmit() }

                        Text(PasswordRule.hint)
                            .font(ReloraFont.footnote)
                            .foregroundStyle(ReloraColor.mutedInk)

                        Button(viewModel.isSubmitting ? "Saving..." : "Save password") {
                            handleSubmit()
                        }
                        .buttonStyle(.reloraPrimary)
                        .disabled(viewModel.isSubmitting)
                        .accessibilityLabel("Save password")
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
