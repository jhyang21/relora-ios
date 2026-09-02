import SwiftUI
import ReloraCore
import ReloraData
import ReloraDesign
import ReloraServices

/// The whole onboarding flow: Welcome → HowItWorks → Personalize → LetsTryIt
/// → GetStarted. Ports `OnboardingNavigator.tsx`'s five screens as one
/// state machine over a persisted step instead of a nested navigation
/// stack — nothing here needs push/pop, since RN's own screens have no back
/// button either (`StepContainer` never renders one).
public struct OnboardingCoordinatorView: View {
    private let database: AppDatabase
    private let identity: IdentityController
    private let toasts: ReloraToastCenter
    private let router: AppRouter
    private let onFinish: () async -> Void
    private let storage: OnboardingStorage

    @State private var step: OnboardingStep = .welcome
    @State private var audience: [String] = []
    @State private var hasLoaded = false

    public init(
        database: AppDatabase,
        identity: IdentityController,
        toasts: ReloraToastCenter,
        router: AppRouter,
        onFinish: @escaping () async -> Void
    ) {
        self.database = database
        self.identity = identity
        self.toasts = toasts
        self.router = router
        self.onFinish = onFinish
        self.storage = OnboardingStorage(database: database)
    }

    public var body: some View {
        Group {
            if hasLoaded {
                switch step {
                case .welcome:
                    OnboardingWelcomeStepView(
                        onNext: { advance(to: .howItWorks) },
                        onSkip: { advance(to: .letsTryIt) }
                    )

                case .howItWorks:
                    OnboardingHowItWorksStepView(
                        onNext: { advance(to: .personalize) },
                        onSkip: { advance(to: .letsTryIt) }
                    )

                case .personalize:
                    OnboardingPersonalizeStepView(
                        audience: $audience,
                        onNext: {
                            storage.writeAudience(audience)
                            advance(to: .letsTryIt)
                        },
                        // Deliberately does not persist `audience` — mirrors
                        // `PersonalizeStep.tsx`'s `handleSkip`, which calls
                        // only `writeOnboardingStep(3)`.
                        onSkip: { advance(to: .letsTryIt) }
                    )

                case .letsTryIt:
                    LetsTryItStepView(
                        database: database,
                        identity: identity,
                        storage: storage,
                        toasts: toasts,
                        onAdvance: { step = .getStarted }
                    )

                case .getStarted:
                    GetStartedStepView(
                        database: database,
                        identity: identity,
                        storage: storage,
                        router: router,
                        onFinish: onFinish
                    )
                }
            } else {
                Color.clear
            }
        }
        .task {
            guard !hasLoaded else { return }
            step = OnboardingStep(clampingStored: storage.readStep())
            audience = storage.readAudience()
            hasLoaded = true
        }
    }

    /// The persisted step number is the destination's own raw value — the
    /// same mapping `OnboardingStep(clampingStored:)` reads back on resume.
    private func advance(to next: OnboardingStep) {
        storage.writeStep(next.rawValue)
        step = next
    }
}

// MARK: - Welcome

private struct OnboardingWelcomeStepView: View {
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        OnboardingStepContainer(
            stepIndex: OnboardingStep.welcome.rawValue,
            totalSteps: OnboardingStep.allCases.count,
            onSkip: onSkip
        ) {
            OnboardingHeroCard {
                HStack(spacing: ReloraSpacing.sm) {
                    Circle().fill(ReloraColor.accent).frame(width: 48, height: 48)
                    Circle().fill(ReloraColor.accentSoft).frame(width: 48, height: 48)
                    Circle().fill(ReloraColor.lavender).frame(width: 48, height: 48)
                }
                .accessibilityHidden(true)
                Text("RELORA")
                    .font(ReloraFont.footnote)
                    .foregroundStyle(ReloraColor.mutedInk)
                    .tracking(1)
                Text("Remember the details that matter about your people.")
                    .font(ReloraFont.largeTitle)
                    .foregroundStyle(ReloraColor.ink)
                Text("Voice-first relationship intelligence. Record a quick note, and we handle the rest.")
                    .font(ReloraFont.body)
                    .foregroundStyle(ReloraColor.mutedInk)
            }
        } footer: {
            Button("Next", action: onNext)
                .buttonStyle(.reloraPrimary)
                .accessibilityLabel("Next")
        }
    }
}

// MARK: - How it works

private struct OnboardingHowItWorksStepView: View {
    let onNext: () -> Void
    let onSkip: () -> Void

    /// Scales with the row's text, so the badge does not sit as a 48pt puck
    /// beside 40pt copy at accessibility sizes (same pattern as `ReloraAvatar`).
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 48

    private struct Step: Identifiable {
        let id = UUID()
        let symbol: String
        let accent: Color
        let title: String
        let body: String
    }

    // Glyphs rather than emoji, matching RN's own reasoning: emoji render in
    // the platform font's own color and style regardless of the palette.
    // SF Symbols stand in for RN's MaterialCommunityIcons glyphs (a
    // different icon set — same intent, not a pixel port).
    private let steps = [
        Step(symbol: "mic.fill", accent: ReloraColor.accent, title: "Record a voice note", body: "Talk about someone for up to a minute. Just say what happened."),
        Step(symbol: "wand.and.stars", accent: ReloraColor.accentSoft, title: "AI extracts the details", body: "Memories, key things, and reminders — automatically."),
        Step(symbol: "book.fill", accent: ReloraColor.lavender, title: "Build relationship history", body: "Everything organized by person. Search anytime."),
    ]

    var body: some View {
        OnboardingStepContainer(
            stepIndex: OnboardingStep.howItWorks.rawValue,
            totalSteps: OnboardingStep.allCases.count,
            onSkip: onSkip
        ) {
            VStack(spacing: ReloraSpacing.md) {
                ForEach(steps) { step in
                    HStack(spacing: ReloraSpacing.md) {
                        ZStack {
                            Circle().fill(step.accent).frame(width: badgeSize, height: badgeSize)
                            Image(systemName: step.symbol).foregroundStyle(ReloraColor.ink)
                        }
                        // The glyph restates the title beside it; announcing it
                        // would only add "wand and stars" to the row.
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title)
                                .font(ReloraFont.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(ReloraColor.ink)
                            Text(step.body)
                                .font(ReloraFont.footnote)
                                .foregroundStyle(ReloraColor.mutedInk)
                        }
                        Spacer()
                    }
                    .padding(ReloraSpacing.md)
                    .reloraSurface(ReloraColor.card, radius: ReloraRadius.lg, shadow: .card)
                    .accessibilityElement(children: .combine)
                }
            }
        } footer: {
            Button("Next", action: onNext)
                .buttonStyle(.reloraPrimary)
                .accessibilityLabel("Next")
        }
    }
}

// MARK: - Personalize

private struct OnboardingPersonalizeStepView: View {
    @Binding var audience: [String]
    let onNext: () -> Void
    let onSkip: () -> Void

    private let options = ["Family", "Friends", "Colleagues", "Clients", "Everyone"]

    var body: some View {
        OnboardingStepContainer(
            stepIndex: OnboardingStep.personalize.rawValue,
            totalSteps: OnboardingStep.allCases.count,
            onSkip: onSkip
        ) {
            VStack(alignment: .leading, spacing: ReloraSpacing.md) {
                Text("Who do you want to remember better?")
                    .font(ReloraFont.title3)
                    .foregroundStyle(ReloraColor.ink)

                // RN's `flexWrap`. M10 chunked these into fixed rows of two,
                // which clips rather than wraps once type scales — at
                // accessibility sizes two pills no longer fit side by side.
                ReloraFlowLayout(
                    horizontalSpacing: ReloraSpacing.sm,
                    verticalSpacing: ReloraSpacing.sm
                ) {
                    ForEach(options, id: \.self) { option in
                        OnboardingPillButton(
                            label: option,
                            selected: audience.contains(option),
                            action: { toggle(option) }
                        )
                    }
                }
            }
        } footer: {
            Button("Next", action: onNext)
                .buttonStyle(.reloraPrimary)
                .accessibilityLabel("Next")
        }
    }

    private func toggle(_ option: String) {
        if audience.contains(option) {
            audience.removeAll { $0 == option }
        } else {
            audience.append(option)
        }
    }
}
