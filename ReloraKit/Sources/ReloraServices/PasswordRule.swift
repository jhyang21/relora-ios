import Foundation

/// The one password rule this app applies, so the two places that ask for
/// a password — sign-up (`AuthGateView`) and set-new-password
/// (`SetNewPasswordViewModel`) — cannot drift apart or from the server.
///
/// The server rejects anything weaker with an error the user reads after
/// a round trip. Checking the same rule locally turns that into an
/// immediate hint, so the rule and the hint text live together here.
public enum PasswordRule {
    public static let minimumLength = 8

    /// What the form says under the field, and what a rejection repeats.
    public static let hint = "Use at least 8 characters, with an uppercase letter, a lowercase letter and a number."

    public enum Failure: Equatable, Sendable {
        case tooShort
        case missingUppercase
        case missingLowercase
        case missingDigit
    }

    /// `nil` when `password` is acceptable. The first failing rule is
    /// returned rather than every one of them: a caller shows `hint`,
    /// which states all four, so a list of failures would only repeat it.
    ///
    /// Character classes are ASCII on purpose. The server counts the same
    /// way, and a rule that accepted a Cyrillic capital as "an uppercase
    /// letter" would pass here and fail there.
    public static func validate(_ password: String) -> Failure? {
        guard password.count >= minimumLength else { return .tooShort }
        guard password.contains(where: { $0.isASCII && $0.isUppercase }) else { return .missingUppercase }
        guard password.contains(where: { $0.isASCII && $0.isLowercase }) else { return .missingLowercase }
        guard password.contains(where: { $0.isASCII && $0.isNumber }) else { return .missingDigit }
        return nil
    }

    /// The toast title for a rejection. The body is always `hint`.
    public static func title(for failure: Failure) -> String {
        switch failure {
        case .tooShort: return "Password too short"
        case .missingUppercase, .missingLowercase, .missingDigit: return "Password too simple"
        }
    }
}
