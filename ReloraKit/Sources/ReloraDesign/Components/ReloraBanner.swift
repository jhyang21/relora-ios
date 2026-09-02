import SwiftUI

/// The app talking about itself: offline, sync failed, a migration still
/// running. Never about the user's content — that is what a toast is for.
///
/// One banner at a time. The precedence that decides which one is a screen
/// concern, not a component concern; see `HomeBannerState` in ReloraFeatures.
public struct ReloraBanner: View {
    public enum Tone {
        /// Neutral system state — offline. Sits on the gray `offlineSurface`.
        case system
        /// Something failed and the user can retry.
        case warning
    }

    private let tone: Tone
    private let title: String
    private let message: String?
    private let retryLabel: String?
    private let onRetry: (() -> Void)?

    public init(
        tone: Tone,
        title: String,
        message: String? = nil,
        retryLabel: String? = "Retry",
        onRetry: (() -> Void)? = nil
    ) {
        self.tone = tone
        self.title = title
        self.message = message
        self.retryLabel = retryLabel
        self.onRetry = onRetry
    }

    private var surface: Color {
        switch tone {
        case .system: return ReloraColor.offlineSurface
        case .warning: return ReloraColor.warmTintStrong
        }
    }

    /// `offlineSurface` is the one surface where `mutedInk`, `accentText` and
    /// `danger` all miss AA in light mode (see `Palette.swift`). So a system
    /// banner is plain `ink` throughout — no color carries meaning here, the
    /// wording does.
    private var titleColor: Color {
        ReloraColor.ink
    }

    private var messageColor: Color {
        switch tone {
        case .system: return ReloraColor.ink
        case .warning: return ReloraColor.mutedInk
        }
    }

    private var retryColor: Color {
        switch tone {
        case .system: return ReloraColor.ink
        case .warning: return ReloraColor.accentText
        }
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ReloraSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ReloraFont.footnote)
                    .foregroundStyle(titleColor)
                if let message {
                    Text(message)
                        .font(ReloraFont.footnote)
                        .foregroundStyle(messageColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if let onRetry, let retryLabel {
                Button(retryLabel, action: onRetry)
                    .font(ReloraFont.footnote)
                    .foregroundStyle(retryColor)
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, ReloraSpacing.md)
        .padding(.vertical, ReloraSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .reloraSurface(surface, radius: ReloraRadius.sm, shadow: .card)
    }
}
