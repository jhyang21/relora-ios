import Foundation
import ReloraDesign
import ReloraServices

/// Ports `SetNewPasswordScreen.tsx`'s `onSubmit`.
@MainActor
@Observable
public final class SetNewPasswordViewModel {
    public enum ValidationError: Equatable, Sendable {
        case weak(PasswordRule.Failure)
        case mismatch
    }

    public var password = ""
    public var confirmPassword = ""
    public private(set) var isSubmitting = false

    /// What went wrong, said under the field it belongs to.
    ///
    /// These used to be toasts. A toast on a password form appears behind the
    /// keyboard, erases itself after four seconds, and takes the rule with it
    /// — so the user reads half a sentence about a password they can no
    /// longer see. At most one of the three is set at a time, which keeps
    /// VoiceOver to a single announcement.
    public private(set) var passwordError: String?
    public private(set) var confirmError: String?
    public private(set) var formError: String?

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
        clearErrors()

        if let validationError = Self.validate(password: password, confirmPassword: confirmPassword) {
            switch validationError {
            case .weak:
                passwordError = PasswordRule.hint
            case .mismatch:
                confirmError = "Both fields have to hold the same password."
            }
            return false
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            try await identity.updatePassword(password)
            // The one thing that still belongs in a toast: the sheet is
            // closing, so there is no form left to put the message on.
            toasts.show("Password updated", message: "Your password has been changed.", variant: .success)
            identity.acknowledgePasswordRecovery()
            return true
        } catch {
            // Never `error.localizedDescription`. RN reported the backend's
            // own message and so did this screen; `AuthErrorCopy` turns the
            // same throw into a sentence written for the person reading it.
            formError = AuthErrorCopy.forError(error, intent: .updatePassword).message
            return false
        }
    }

    /// Called when either field changes. An error that describes text the
    /// user is already replacing is noise.
    public func inputChanged() {
        guard passwordError != nil || confirmError != nil || formError != nil else { return }
        clearErrors()
    }

    private func clearErrors() {
        passwordError = nil
        confirmError = nil
        formError = nil
    }
}
