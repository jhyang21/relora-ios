import Foundation
import ReloraDesign
import ReloraServices

/// Ports `SetNewPasswordScreen.tsx`'s `onSubmit`.
@MainActor
@Observable
public final class SetNewPasswordViewModel {
    /// The rule the server enforces, stated once in `PasswordRule` and
    /// re-exported here so the view keeps reading it off this type.
    public static let passwordRequirementsHint = PasswordRule.hint

    public enum ValidationError: Equatable, Sendable {
        case weak(PasswordRule.Failure)
        case mismatch
    }

    public var password = ""
    public var confirmPassword = ""
    public private(set) var isSubmitting = false

    private let identity: IdentityController
    private let toasts: ReloraToastCenter

    public init(identity: IdentityController, toasts: ReloraToastCenter) {
        self.identity = identity
        self.toasts = toasts
    }

    /// Whether the recovery link failed to establish a session — already
    /// used or expired. RN announces this with a toast and never shows the
    /// screen (`PasswordRecoveryBridge.tsx`); native opens the sheet either
    /// way (see `AppRouter.handle`) and says so here instead, with RN's
    /// copy. The form stays usable: a user who was already signed in still
    /// holds a valid session, and `submit()` surfaces any real auth failure.
    public var recoveryLinkFailed: Bool {
        identity.passwordRecoveryStatus == .error
    }

    /// Called when the sheet disappears. RN's navigation gating forces the
    /// screen until recovery is acknowledged; a SwiftUI sheet can be swiped
    /// away, so this clears `.pending`/`.error` rather than letting either
    /// linger. Idempotent after a successful `submit()`, which already
    /// acknowledged.
    public func handleDisappear() {
        identity.acknowledgePasswordRecovery()
    }

    /// The two guard clauses `onSubmit` checks before calling
    /// `supabase.auth.updateUser`, kept pure and static so they are
    /// testable without an `IdentityController`.
    public static func validate(password: String, confirmPassword: String) -> ValidationError? {
        if let failure = PasswordRule.validate(password) { return .weak(failure) }
        guard password == confirmPassword else { return .mismatch }
        return nil
    }

    /// Returns whether the password was updated — the view dismisses on
    /// `true`, matching `acknowledgePasswordRecoveryComplete()` handing
    /// control back to normal signed-in navigation on success.
    public func submit() async -> Bool {
        guard !isSubmitting else { return false }

        if let validationError = Self.validate(password: password, confirmPassword: confirmPassword) {
            switch validationError {
            case .weak(let failure):
                toasts.showError(PasswordRule.title(for: failure), message: Self.passwordRequirementsHint)
            case .mismatch:
                toasts.showError("Passwords do not match", message: "Re-enter the same password in both fields.")
            }
            return false
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            try await identity.updatePassword(password)
            toasts.show("Password updated", message: "Your password has been changed.", variant: .success)
            identity.acknowledgePasswordRecovery()
            return true
        } catch {
            // RN reports `error.message`; `localizedDescription` is the
            // closest native equivalent to "whatever the auth backend said",
            // not a re-derivation of RN's own message text.
            toasts.showError("Could not update password", message: error.localizedDescription)
            return false
        }
    }
}
