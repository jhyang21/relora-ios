import Testing
@testable import ReloraFeatures
import ReloraServices

@Suite("SetNewPasswordViewModel.validate")
@MainActor
struct SetNewPasswordViewModelValidateTests {
    @Test("A password under 8 characters is too short, even if confirm matches")
    func tooShortWinsFirst() {
        #expect(SetNewPasswordViewModel.validate(password: "Abc1", confirmPassword: "Abc1") == .weak(.tooShort))
    }

    @Test("Strength is checked before the two fields are compared")
    func strengthWinsOverMismatch() {
        #expect(SetNewPasswordViewModel.validate(password: "abcdefgh", confirmPassword: "zzzzzzzz") == .weak(.missingUppercase))
    }

    @Test("A strong password that does not match confirm is a mismatch")
    func mismatchAfterStrengthPasses() {
        #expect(SetNewPasswordViewModel.validate(password: "Abcdefg1", confirmPassword: "Abcdefg2") == .mismatch)
    }

    @Test("A strong password matching confirm validates clean")
    func validPasses() {
        #expect(SetNewPasswordViewModel.validate(password: "Abcdefg1", confirmPassword: "Abcdefg1") == nil)
    }
}
