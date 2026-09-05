import SwiftUI
import ReloraDesign

/// The one-time "How voice notes work" panel, shown inside the composer
/// sheet before the first recording ever starts.
///
/// Laid out like `ReminderNotificationPrimingSheet` — hero glyph, heading,
/// body, primary action, muted "Not now" — because it does the same job: it
/// explains a thing the OS is about to ask for, in the moment it becomes
/// relevant, rather than in an onboarding step nobody reads.
///
/// A pre-state of the composer rather than a sheet of its own. Presenting a
/// second sheet over the composer would break the app's one-sheet rule and
/// put two dismiss gestures on screen at once.
struct VoiceDisclosurePanel: View {
    let onContinue: () -> Void
    let onNotNow: () -> Void

    /// Scaled rather than fixed: a hero glyph that stays 40pt beside 40pt
    /// copy reads as an icon that failed to load.
    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 40

    var body: some View {
        VStack(spacing: ReloraSpacing.lg) {
            Spacer(minLength: 0)

            Image(systemName: "waveform")
                .font(.system(size: glyphSize))
                .foregroundStyle(ReloraColor.accentText)
                // Ornamental; the heading below says the same thing in words.
                .accessibilityHidden(true)

            VStack(spacing: ReloraSpacing.sm) {
                Text(VoiceCaptureCopy.disclosureTitle)
                    .font(ReloraFont.title3)
                    .foregroundStyle(ReloraColor.ink)
                    .multilineTextAlignment(.center)

                Text(VoiceCaptureCopy.disclosureBody)
                    .font(ReloraFont.body)
                    .foregroundStyle(ReloraColor.mutedInk)
                    .multilineTextAlignment(.center)

                Text(VoiceCaptureCopy.disclosurePrivacy)
                    .font(ReloraFont.footnote)
                    .foregroundStyle(ReloraColor.mutedInk)
                    .multilineTextAlignment(.center)

                Text(VoiceCaptureCopy.disclosureMicNotice)
                    .font(ReloraFont.footnote)
                    .foregroundStyle(ReloraColor.mutedInk)
                    .multilineTextAlignment(.center)

                Link(VoiceCaptureCopy.disclosurePrivacyLink, destination: SettingsLegal.privacyPolicyURL)
                    .font(ReloraFont.footnote)
                    .foregroundStyle(ReloraColor.accentText)
                    .accessibilityHint("Opens in Safari")
            }

            Spacer(minLength: 0)

            VStack(spacing: ReloraSpacing.sm) {
                Button(VoiceCaptureCopy.disclosureContinue, action: onContinue)
                    .buttonStyle(.reloraPrimary)
                Button(VoiceCaptureCopy.disclosureNotNow, action: onNotNow)
                    .foregroundStyle(ReloraColor.mutedInk)
                    .frame(minHeight: 44)
                    // Without this the tap target is the text, not the 44pt row.
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, ReloraLayout.screenHPadding)
        .padding(.vertical, ReloraSpacing.lg)
        .frame(maxWidth: ReloraLayout.contentMaxWidth)
        .frame(maxWidth: .infinity)
    }
}
