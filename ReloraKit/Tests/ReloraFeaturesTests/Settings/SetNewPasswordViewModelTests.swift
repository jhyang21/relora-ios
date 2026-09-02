import Testing
@testable import ReloraFeatures

@Suite("SetNewPasswordViewModel.validate")
struct SetNewPasswordViewModelValidateTests {
    @Test("A password under 6 characters is too short, even if confirm matches")
    func tooShortWinsFirst() {
        #expect(SetNewPasswordViewModel.validate(password: "abc", confirmPassword: "abc") == .tooShort)
    }

    @Test("A 6-character password that does not match confirm is a mismatch")
    func mismatchAfterLengthPasses() {
        #expect(SetNewPasswordViewModel.validate(password: "abcdef", confirmPassword: "abcdeg") == .mismatch)
    }

    @Test("A 6-character password matching confirm validates clean")
    func validPasses() {
        #expect(SetNewPasswordViewModel.validate(password: "abcdef", confirmPassword: "abcdef") == nil)
    }

    @Test("Exactly 5 characters is still too short — the boundary is inclusive at 6")
    func fiveCharactersIsTooShort() {
        #expect(SetNewPasswordViewModel.validate(password: "abcde", confirmPassword: "abcde") == .tooShort)
    }

    @Test("An empty password is too short, not a mismatch")
    func emptyPasswordIsTooShort() {
        #expect(SetNewPasswordViewModel.validate(password: "", confirmPassword: "") == .tooShort)
    }
}
