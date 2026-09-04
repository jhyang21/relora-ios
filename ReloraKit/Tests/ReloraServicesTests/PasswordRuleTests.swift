import Testing
@testable import ReloraServices

@Suite("PasswordRule.validate")
struct PasswordRuleTests {
    @Test("Seven characters is too short — the boundary is inclusive at 8")
    func tooShort() {
        #expect(PasswordRule.validate("Abcdef1") == .tooShort)
    }

    @Test("An empty password is too short")
    func empty() {
        #expect(PasswordRule.validate("") == .tooShort)
    }

    @Test("Length is checked before the character classes")
    func lengthWinsFirst() {
        #expect(PasswordRule.validate("abc") == .tooShort)
    }

    @Test("All lowercase and digits still needs a capital")
    func missingUppercase() {
        #expect(PasswordRule.validate("abcdefg1") == .missingUppercase)
    }

    @Test("All caps and digits still needs a lowercase letter")
    func missingLowercase() {
        #expect(PasswordRule.validate("ABCDEFG1") == .missingLowercase)
    }

    @Test("Letters alone are not enough without a digit")
    func missingDigit() {
        #expect(PasswordRule.validate("Abcdefgh") == .missingDigit)
    }

    @Test("Eight characters with all three classes passes")
    func valid() {
        #expect(PasswordRule.validate("Abcdefg1") == nil)
    }

    @Test("Punctuation is allowed, it just does not stand in for a class")
    func punctuationIsNeutral() {
        #expect(PasswordRule.validate("Abcdef1!") == nil)
        #expect(PasswordRule.validate("!!!!!!!!") == .missingUppercase)
    }

    /// The server counts ASCII classes. A Cyrillic capital must not pass
    /// here and then be rejected there.
    @Test("Non-ASCII letters do not satisfy the uppercase rule")
    func nonASCIIDoesNotCount() {
        #expect(PasswordRule.validate("Бcdefgh1") == .missingUppercase)
    }
}
