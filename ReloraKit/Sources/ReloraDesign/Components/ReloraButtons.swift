import SwiftUI

/// The filled action. Coral fill, `onAccent` label — the one pairing that
/// survives both modes (see `Palette.swift`).
///
/// A `ButtonStyle` rather than a wrapper view so callers keep writing
/// `Button("Save") { … }` and get accessibility, hit testing, and the disabled
/// state from SwiftUI instead of re-implementing them.
public struct ReloraPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ReloraFont.body)
            .foregroundStyle(ReloraColor.onAccent)
            .frame(maxWidth: .infinity)
            // A minimum, never a fixed height: at accessibility text sizes the
            // label has to be allowed to grow the button rather than clip.
            .frame(minHeight: 52)
            .padding(.horizontal, ReloraSpacing.lg)
            .padding(.vertical, ReloraSpacing.sm)
            .background(
                Capsule(style: .continuous).fill(ReloraColor.accent)
            )
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .reloraAnimation(.quick, value: configuration.isPressed)
    }
}

/// The quieter action beside a primary one — Cancel, "Change selection",
/// anything that is a real choice but not the expected one.
public struct ReloraSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ReloraFont.body)
            .foregroundStyle(ReloraColor.ink)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .padding(.horizontal, ReloraSpacing.lg)
            .padding(.vertical, ReloraSpacing.sm)
            .background(
                Capsule(style: .continuous).fill(ReloraColor.card)
            )
            .overlay(
                Capsule(style: .continuous).strokeBorder(ReloraColor.hairline, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .reloraAnimation(.quick, value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == ReloraPrimaryButtonStyle {
    static var reloraPrimary: ReloraPrimaryButtonStyle { ReloraPrimaryButtonStyle() }
}

public extension ButtonStyle where Self == ReloraSecondaryButtonStyle {
    static var reloraSecondary: ReloraSecondaryButtonStyle { ReloraSecondaryButtonStyle() }
}
