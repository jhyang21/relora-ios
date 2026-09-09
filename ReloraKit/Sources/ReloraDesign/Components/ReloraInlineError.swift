import SwiftUI

/// A validation or submit failure, said where it happened.
///
/// The app's other failure channel is `ReloraToast`, which erases itself after
/// four seconds and appears at the bottom of the screen — behind the keyboard
/// on any form. That is right for "your note saved" and wrong for "that
/// password doesn't match", which the user has to read *while* fixing the
/// field it belongs to. Form failures use this; everything else keeps the toast.
///
/// The icon is not decoration. `danger` carries the meaning, and color alone
/// carries nothing to a user who cannot separate it from `ink` — the symbol is
/// the second channel that makes the message legible without it.
public struct ReloraInlineError: View {
    private let message: String
    private let announces: Bool

    /// - Parameter announces: posts the message to VoiceOver when the view
    ///   appears. On by default, because an error that only exists on screen is
    ///   an error a VoiceOver user submits into twice. Pass `false` for the
    ///   second of two errors appearing together, so they do not talk over
    ///   each other.
    public init(_ message: String, announces: Bool = true) {
        self.message = message
        self.announces = announces
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ReloraSpacing.xs) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(ReloraFont.footnote)
                .accessibilityHidden(true)
            Text(message)
                .font(ReloraFont.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(ReloraColor.danger)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error. \(message)")
        .onAppear {
            guard announces else { return }
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

/// A hairline rule with a word set into it — what separates a one-tap sign-in
/// option from the email form beneath it.
///
/// Hidden from VoiceOver on purpose. It is a drawing of a separation the
/// heading structure already states, and reading "or" between two buttons adds
/// nothing to navigate by.
public struct ReloraOrDivider: View {
    private let label: String

    public init(_ label: String = "or") {
        self.label = label
    }

    public var body: some View {
        HStack(spacing: ReloraSpacing.sm) {
            rule
            Text(label)
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.mutedInk)
            rule
        }
        .accessibilityHidden(true)
    }

    private var rule: some View {
        Rectangle()
            .fill(ReloraColor.hairline)
            .frame(height: 1)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: ReloraSpacing.lg) {
        ReloraInlineError("That email or password doesn't match.")
        ReloraOrDivider()
        ReloraInlineError("You're offline. Check your connection and try again.")
    }
    .padding(ReloraSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ReloraColor.background)
}
