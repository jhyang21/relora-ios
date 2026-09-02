import Testing
@testable import ReloraFeatures

@Suite("OnboardingStep")
struct OnboardingStepTests {
    @Test("clampingStored clamps below range down to .welcome")
    func clampsBelowRange() {
        #expect(OnboardingStep(clampingStored: -5) == .welcome)
        #expect(OnboardingStep(clampingStored: 0) == .welcome)
    }

    @Test("clampingStored clamps above range up to .getStarted")
    func clampsAboveRange() {
        #expect(OnboardingStep(clampingStored: 99) == .getStarted)
        #expect(OnboardingStep(clampingStored: 4) == .getStarted)
    }

    @Test("clampingStored passes an in-range value through unchanged")
    func passesInRangeThrough() {
        #expect(OnboardingStep(clampingStored: 2) == .personalize)
    }

    @Test("next steps through the full sequence and stops after getStarted")
    func nextWalksTheSequence() {
        #expect(OnboardingStep.welcome.next == .howItWorks)
        #expect(OnboardingStep.howItWorks.next == .personalize)
        #expect(OnboardingStep.personalize.next == .letsTryIt)
        #expect(OnboardingStep.letsTryIt.next == .getStarted)
        #expect(OnboardingStep.getStarted.next == nil)
    }

    @Test("skipDestination: Welcome, HowItWorks, and Personalize all skip to LetsTryIt, never straight to GetStarted")
    func earlyStepsSkipToLetsTryIt() {
        #expect(OnboardingStep.welcome.skipDestination == .letsTryIt)
        #expect(OnboardingStep.howItWorks.skipDestination == .letsTryIt)
        #expect(OnboardingStep.personalize.skipDestination == .letsTryIt)
    }

    @Test("skipDestination: LetsTryIt's own skip lands on GetStarted")
    func letsTryItSkipsToGetStarted() {
        #expect(OnboardingStep.letsTryIt.skipDestination == .getStarted)
    }

    @Test("skipDestination: GetStarted offers no skip")
    func getStartedHasNoSkip() {
        #expect(OnboardingStep.getStarted.skipDestination == nil)
    }
}
