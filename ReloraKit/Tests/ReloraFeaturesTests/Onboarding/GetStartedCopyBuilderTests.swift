import Testing
@testable import ReloraFeatures

@Suite("GetStartedCopyBuilder.build")
struct GetStartedCopyBuilderTests {
    @Test("A completed tutorial always wins, regardless of audience")
    func completedTutorialWins() {
        let copy = GetStartedCopyBuilder.build(audience: ["clients"], exampleContactName: "Priya Raman", tutorialCompleted: true)
        #expect(copy.heading == "Your example is ready")
        #expect(copy.body.contains("Priya Raman"))
    }

    @Test("No tutorial, but an audience, names up to the first two selections")
    func audienceWithoutTutorialNamesSelections() {
        let copy = GetStartedCopyBuilder.build(audience: ["clients", "old friends", "family"], exampleContactName: "Priya Raman", tutorialCompleted: false)
        #expect(copy.heading == "Ready to remember your clients & old friends")
        #expect(!copy.body.contains("Priya Raman"))
    }

    @Test("No tutorial and no audience falls back to the generic closing copy")
    func noTutorialNoAudienceFallsBack() {
        let copy = GetStartedCopyBuilder.build(audience: [], exampleContactName: "Priya Raman", tutorialCompleted: false)
        #expect(copy.heading == "You're all set")
    }

    @Test("A skipped tutorial never claims an example is ready, even with an audience selected")
    func skippedTutorialNeverClaimsAnExample() {
        let copy = GetStartedCopyBuilder.build(audience: ["clients"], exampleContactName: "Priya Raman", tutorialCompleted: false)
        #expect(copy.heading != "Your example is ready")
    }
}
