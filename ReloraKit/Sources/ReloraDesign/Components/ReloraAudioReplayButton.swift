import SwiftUI

/// The replay control RN calls `AudioReplayButton`. A dumb view — state and
/// the tap action both come from the caller — so it carries no dependency
/// on AVFoundation or `ReloraServices.AudioReplayPlayer`; `ReloraDesign`'s
/// target only depends on `ReloraCore`. `ReloraFeatures.AudioReplayController`
/// owns the actual player and maps its `AudioReplayState` onto `Style`.
public struct ReloraAudioReplayButton: View {
    public enum Style: Equatable {
        case idle
        case playing
        case paused
        case failed
    }

    private let style: Style
    private let action: () -> Void

    public init(style: Style, action: @escaping () -> Void) {
        self.style = style
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: ReloraSpacing.xs) {
                // Same role as the label beside it, so it takes the same
                // Dynamic-Type-scaled metrics rather than a fixed point size.
                Image(systemName: iconName)
                    .font(ReloraFont.footnote)
                Text(label)
                    .font(ReloraFont.footnote)
            }
            .foregroundStyle(ReloraColor.accentText)
            .padding(.horizontal, ReloraSpacing.md)
            .padding(.vertical, ReloraSpacing.xs)
            .background(Capsule(style: .continuous).fill(ReloraColor.warmTintStrong))
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .disabled(style == .failed)
        .reloraAnimation(.quick, value: style == .playing)
        .accessibilityLabel(label)
        .accessibilityHint(style == .playing ? "" : "Plays back the recording")
    }

    private var iconName: String {
        switch style {
        case .playing: return "pause.circle.fill"
        case .paused, .idle: return "play.circle.fill"
        case .failed: return "exclamationmark.circle"
        }
    }

    private var label: String {
        switch style {
        case .playing: return "Pause audio"
        case .paused, .idle: return "Play audio"
        case .failed: return "Could not play audio"
        }
    }
}
