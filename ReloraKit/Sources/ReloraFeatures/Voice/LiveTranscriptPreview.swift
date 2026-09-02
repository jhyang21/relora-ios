import SwiftUI
import ReloraDesign

/// The panel shown under the meter during a realtime capture. Ports RN's
/// `LiveTranscriptPreview`: a three-line placeholder before anything has
/// been said, replaced by the transcript itself as it builds.
///
/// Only ever shown when `VoiceCaptureViewModel.isLiveTranscribing` is
/// true — a batch capture has no live transcript to preview, and showing
/// an empty panel for one would promise something the pipeline cannot
/// deliver, exactly the lie `VoiceCaptureCopy.recordingSubtitle` was
/// written to avoid.
struct LiveTranscriptPreview: View {
    let transcript: String

    var body: some View {
        ReloraCard {
            Group {
                if transcript.trimmed.isEmpty {
                    VStack(alignment: .leading, spacing: ReloraSpacing.xs) {
                        Text(VoiceCaptureCopy.liveTranscriptPlaceholderLine1)
                        Text(VoiceCaptureCopy.liveTranscriptPlaceholderLine2)
                        Text(VoiceCaptureCopy.liveTranscriptPlaceholderLine3)
                    }
                    .font(ReloraFont.footnote)
                    .foregroundStyle(ReloraColor.mutedInk)
                } else {
                    Text(transcript)
                        .font(ReloraFont.body)
                        .foregroundStyle(ReloraColor.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .reloraAnimation(.gentle, value: transcript.isEmpty)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            transcript.trimmed.isEmpty ? "Waiting to hear you" : "Live transcript: \(transcript)"
        )
    }
}
