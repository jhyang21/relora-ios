import Testing
@testable import ReloraCore

@Suite("Review prompt policy")
struct ReviewPromptPolicyTests {
    @Test("asks once, from the third saved note on")
    func shouldPrompt() {
        #expect(ReviewPromptPolicy.shouldPrompt(savedNoteCount: 0, alreadyShown: false) == false)
        #expect(ReviewPromptPolicy.shouldPrompt(savedNoteCount: 2, alreadyShown: false) == false)
        #expect(ReviewPromptPolicy.shouldPrompt(savedNoteCount: 3, alreadyShown: false) == true)
        #expect(ReviewPromptPolicy.shouldPrompt(savedNoteCount: 4, alreadyShown: false) == true)
        #expect(ReviewPromptPolicy.shouldPrompt(savedNoteCount: 3, alreadyShown: true) == false)
    }
}
