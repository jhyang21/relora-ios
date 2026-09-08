import Foundation

/// Display formatting for phone numbers, ported 1:1 from
/// `apps/mobile/src/utils/phoneNumber.ts`. No dependency and no locale
/// database.
///
/// Only North American numbers are reshaped, because those are the only ones
/// whose grouping can be worked out from the digits alone. Everything else —
/// international numbers, short codes, anything carrying an extension — is
/// handed back as the user typed it. Guessing at a French or Korean number's
/// grouping would make it harder to read, not easier.
public enum PhoneNumberFormat {
    private static let nanpDigits = 10

    /// Digits only, so "+1 (555) 555-0147" and "5555550147" compare the same.
    ///
    /// ASCII digits only: `Character.isNumber` is also true for "٣" and "Ⅷ",
    /// neither of which belongs in a dialable string.
    private static func extractDigits(_ value: String) -> [Character] {
        Array(value.filter { ("0"..."9").contains($0) })
    }

    /// Area code and exchange both start 2–9 in every NANP number, so a
    /// ten-digit run failing this is some other country's number stored in
    /// local form — an Australian "02 9374 4000" must not come back as
    /// "(029) 374-4000".
    ///
    /// A hand-rolled check rather than `NSRegularExpression`: RN's
    /// `/^[2-9]\d{2}[2-9]\d{6}$/` is two positional tests over a string this
    /// function already knows is ten digits long, and a regex engine spun up
    /// per row of a contact list buys nothing.
    private static func isNANP(_ digits: [Character]) -> Bool {
        guard digits.count == nanpDigits else { return false }
        return ("2"..."9").contains(digits[0]) && ("2"..."9").contains(digits[3])
    }

    private static func groupNANP(_ digits: [Character]) -> String {
        let area = String(digits[0..<3])
        let exchange = String(digits[3..<6])
        let line = String(digits[6...])
        return "(\(area)) \(exchange)-\(line)"
    }

    /// Formats a stored phone number for display. Returns the trimmed input
    /// unchanged whenever it is not a plain North American number.
    public static func display(_ raw: String) -> String {
        let trimmed = raw.trimmed
        guard !trimmed.isEmpty else { return "" }

        // A "+" that is not "+1" names a country this formatter knows
        // nothing about.
        if trimmed.hasPrefix("+") && !trimmed.hasPrefix("+1") {
            return trimmed
        }

        let digits = extractDigits(trimmed)
        if isNANP(digits) {
            return groupNANP(digits)
        }

        if digits.count == nanpDigits + 1, digits[0] == "1" {
            let tail = Array(digits[1...])
            if isNANP(tail) {
                return "+1 \(groupNANP(tail))"
            }
        }

        return trimmed
    }

    /// The same number in the shape a `tel:` URL takes: a leading `+` when
    /// the stored value had one, then digits and nothing else. Nil when there
    /// are no digits at all, so a caller never builds a link that dials
    /// nothing.
    ///
    /// Not a port — RN's screen hands the raw string to `Linking.openURL` —
    /// but a `tel:` URL built from an unescaped string carrying spaces and
    /// parentheses is a URL that fails to parse, which is the bug this
    /// avoids.
    public static func dialable(_ raw: String) -> String? {
        let trimmed = raw.trimmed
        let digits = String(extractDigits(trimmed))
        guard !digits.isEmpty else { return nil }
        return trimmed.hasPrefix("+") ? "+\(digits)" : digits
    }
}
