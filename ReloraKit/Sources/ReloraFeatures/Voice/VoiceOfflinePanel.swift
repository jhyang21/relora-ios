import SwiftUI
import ReloraDesign

/// The "You're offline" refusal, shown inside the composer sheet when a
/// signed-in account taps record with no network.
///
/// Laid out like `VoiceDisclosurePanel` — hero glyph, heading, body, primary
/// action, muted exit — because it is the same kind of screen: a pre-state
/// that holds the microphone and says why. A user who meets both panels in
/// one session should not have to read two different shapes.
///
/// A pre-state of the composer rather than a sheet or an alert of its own.
/// An alert over the composer would put two dismiss gestures on screen and
/// leave the sheet sitting empty behind it.
struct VoiceOfflinePanel: View {
    let onTryAgain: () -> Void
    let onClose: () -> Void

    /// Scaled rather than fixed: a hero glyph that stays 40pt beside 40pt
    /// copy reads as an icon that failed to load.
    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 40

    /// Scrolls rather than squeezes, for the same reason the disclosure
    /// panel does: the sheet can be at `.medium`, and a short vertical
    /// proposal is answered with an ellipsis rather than a shorter panel.
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var content: some View {
        VStack(spacing: ReloraSpacing.lg) {
            Spacer(minLength: 0)

            Image(systemName: "wifi.slash")
                .font(.system(size: glyphSize))
                .foregroundStyle(ReloraColor.accentText)
                // Ornamental; the heading below says the same thing in words.
                .accessibilityHidden(true)

            VStack(spacing: ReloraSpacing.sm) {
                Text(VoiceCaptureCopy.offlineTitle)
                    .font(ReloraFont.title3)
                    .foregroundStyle(ReloraColor.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(VoiceCaptureCopy.offlineBody)
                    .font(ReloraFont.body)
                    .foregroundStyle(ReloraColor.mutedInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(spacing: ReloraSpacing.sm) {
                Button(VoiceCaptureCopy.offlineTryAgain, action: onTryAgain)
                    .buttonStyle(.reloraPrimary)
                Button(VoiceCaptureCopy.offlineClose, action: onClose)
                    .foregroundStyle(ReloraColor.mutedInk)
                    .frame(minHeight: 44)
                    // Without this the tap target is the text, not the 44pt row.
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, ReloraLayout.screenHPadding)
        .padding(.vertical, ReloraSpacing.lg)
        .frame(maxWidth: ReloraLayout.contentMaxWidth)
    }
}
