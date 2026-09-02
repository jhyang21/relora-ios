import Testing
import ReloraCore
@testable import ReloraFeatures

@Suite("OnboardingStorage.TutorialState.isCurrent")
struct OnboardingStorageTutorialStateTests {
    @Test(".empty is not current")
    func emptyIsNotCurrent() {
        #expect(OnboardingStorage.TutorialState.empty.isCurrent == false)
    }

    @Test("Completed with the current seed version is current")
    func completedWithCurrentVersionIsCurrent() {
        let state = OnboardingStorage.TutorialState(
            completed: true,
            contactID: "contact-1",
            seedVersion: AppSettingsKey.onboardingTutorialSeedVersionValue
        )
        #expect(state.isCurrent)
    }

    @Test("Completed with an older seed version is not current — a stale persona re-seeds")
    func completedWithStaleVersionIsNotCurrent() {
        let state = OnboardingStorage.TutorialState(completed: true, contactID: "contact-1", seedVersion: "an-older-persona")
        #expect(state.isCurrent == false)
    }

    @Test("Completed with no seed version at all is not current — covers a pre-key device")
    func completedWithNoVersionIsNotCurrent() {
        let state = OnboardingStorage.TutorialState(completed: true, contactID: "contact-1", seedVersion: nil)
        #expect(state.isCurrent == false)
    }

    @Test("The current seed version alone, without completed, is still not current")
    func currentVersionWithoutCompletedIsNotCurrent() {
        let state = OnboardingStorage.TutorialState(
            completed: false,
            contactID: nil,
            seedVersion: AppSettingsKey.onboardingTutorialSeedVersionValue
        )
        #expect(state.isCurrent == false)
    }
}
