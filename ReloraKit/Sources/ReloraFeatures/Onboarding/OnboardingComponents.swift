import SwiftUI
import ReloraDesign

/// Shared chrome for every onboarding step. Ports `StepContainer.tsx`,
/// `OnboardingProgressBar.tsx`, and `OnboardingPill.tsx`.
///
/// M10 wrote these by inferring layout from the step screens; M11 read the three
/// RN files and corrected the spacing, the hero surface, and the touch targets.
/// Remaining deviations from RN, all deliberate:
///
/// - RN's `onboardingStyles.primaryAction` is an ink-filled pill with card-colored
///   text. Native steps use `.reloraPrimary` (coral) so onboarding's buttons match
///   the rest of the app rather than forking a second primary button.
/// - RN's `OnboardingPill` scales to 1.05 when selected. Not ported: a scaled pill
///   overlaps its neighbours inside a wrapping layout, and the coral fill plus the
///   heavier label already carry the selection.
struct OnboardingStepContainer<Content: View, Footer: View>: View {
    let stepIndex: Int
    let totalSteps: Int
    var onSkip: (() -> Void)?
    var skipDisabled: Bool = false
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                OnboardingProgressDots(currentStep: stepIndex, totalSteps: totalSteps)
                Spacer()
                if let onSkip {
                    Button(action: onSkip) {
                        Text("Skip")
                            .font(ReloraFont.body)
                            .fontWeight(.medium)
                            .foregroundStyle(ReloraColor.mutedInk)
                            // RN dims the label itself (`skipTextDisabled`)
                            // rather than substituting a lighter color.
                            .opacity(skipDisabled ? 0.4 : 1)
                            // RN buys the same slack with `hitSlop={10}`; the
                            // bare label is about 20pt tall on its own.
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(skipDisabled)
                    .accessibilityLabel("Skip onboarding")
                }
            }
            .padding(.vertical, ReloraSpacing.md)

            VStack {
                content
            }
            .frame(maxHeight: .infinity)

            VStack(spacing: ReloraSpacing.sm) {
                footer
            }
            .padding(.bottom, ReloraSpacing.md)
        }
        .padding(.horizontal, ReloraLayout.screenHPadding)
        .frame(maxWidth: ReloraLayout.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .background(ReloraColor.background)
    }
}

/// Ports `OnboardingProgressBar.tsx`: a run of dots, the active one widened.
/// Sizes match RN exactly (`DOT_SIZE` 6, `ACTIVE_WIDTH` 24, `gap: spacing.xs`).
private struct OnboardingProgressDots: View {
    let currentStep: Int
    let totalSteps: Int

    var body: some View {
        HStack(spacing: ReloraSpacing.xs) {
            ForEach(0..<totalSteps, id: \.self) { index in
                Capsule()
                    .fill(index == currentStep ? ReloraColor.accent : ReloraColor.hairline)
                    .frame(width: index == currentStep ? 24 : 6, height: 6)
            }
        }
        .reloraAnimation(.spring, value: currentStep)
        // Six shapes are six meaningless stops to VoiceOver, and the step is
        // conveyed nowhere else on the screen — so the row becomes one element
        // that says where the user is.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(currentStep + 1) of \(totalSteps)")
    }
}

/// Ports `OnboardingPill.tsx`. Selection is carried by the coral fill; RN's
/// own comment notes white text on coral only reaches ~2:1 contrast, so
/// selection is shown with a heavier weight instead of an `onAccent` label
/// color — matched here rather than reaching for the higher-contrast token
/// RN deliberately avoided.
struct OnboardingPillButton: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(ReloraFont.body)
                .fontWeight(selected ? .bold : .medium)
                .foregroundStyle(ReloraColor.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, ReloraSpacing.md)
                .padding(.vertical, ReloraSpacing.sm)
                // A minimum, not RN's fixed 44: at accessibility text sizes the
                // label has to grow the pill instead of being clipped by it.
                .frame(minHeight: 44)
                .background(
                    Capsule()
                        .fill(selected ? ReloraColor.accent : ReloraColor.card)
                )
                .overlay(
                    Capsule()
                        .stroke(selected ? ReloraColor.accent : ReloraColor.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .reloraAnimation(.spring, value: selected)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The rounded card every step's hero/summary content sits in. Ports
/// `onboardingStyles.heroCard` (`styles.ts`): `radii.xl`, `spacing.xl` padding,
/// `spacing.md` gap, and the warm `#FFF7EF` surface — which is `warmCard`, not
/// the white `card` M10 inferred.
struct OnboardingHeroCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: ReloraSpacing.md) {
            content
        }
        .padding(ReloraSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ReloraRadius.xl, style: .continuous)
                .fill(ReloraColor.warmCard)
        )
    }
}
