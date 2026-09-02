import Foundation

/// The five onboarding steps, in order. Mirrors `ONBOARDING_STEP_NAMES`
/// (types.ts) and the `OnboardingNavigator` stack it drives.
public enum OnboardingStep: Int, CaseIterable, Equatable, Sendable {
    case welcome = 0
    case howItWorks = 1
    case personalize = 2
    case letsTryIt = 3
    case getStarted = 4

    /// Clamps a persisted step number into range, the same way
    /// `OnboardingNavigator` clamps `readOnboardingStep()`'s result before
    /// picking an `initialRouteName` — a value from an older or newer build
    /// (schema drift, a corrupted row) resumes at the nearest real step
    /// instead of crashing or refusing to render.
    public init(clampingStored value: Int) {
        let clamped = min(max(value, OnboardingStep.welcome.rawValue), OnboardingStep.getStarted.rawValue)
        self = OnboardingStep(rawValue: clamped) ?? .welcome
    }

    /// The step Next/Continue lands on from this one. `getStarted` has no
    /// next step — Next is not offered there.
    public var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }

    /// Where Skip lands from this step.
    ///
    /// **Not** a blanket "skip always goes to GetStarted." RN's skip button
    /// on Welcome, HowItWorks, and Personalize each write step 3 and land on
    /// LetsTryIt — the sample-example step is never itself skipped by this
    /// button. LetsTryIt has its own separate skip action
    /// (`runSkipLetsTryItAction`) that writes step 4 and lands on
    /// GetStarted; `getStarted` offers no skip at all. See the M10 report —
    /// team-lead's original framing ("skip on any step jumps to
    /// GetStarted") does not match RN source and is corrected here.
    public var skipDestination: OnboardingStep? {
        switch self {
        case .welcome, .howItWorks, .personalize: return .letsTryIt
        case .letsTryIt: return .getStarted
        case .getStarted: return nil
        }
    }
}
