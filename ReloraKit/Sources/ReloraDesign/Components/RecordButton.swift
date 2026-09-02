import SwiftUI

/// The one floating action on Home: a coral circle with a microphone.
///
/// ## Why there is only one
///
/// RN floated a coral button that expanded into a speed dial (record / add
/// contact). The design direction retires that: Voice Memos, Camera and Photos
/// all float exactly one action, and "add contact" is a toolbar `+`, not a
/// petal on a flower. A single button also means a single VoiceOver target
/// instead of a custom expanding menu nobody can navigate.
///
/// ## The glow
///
/// `ReloraShadow.accentGlow` is emitted light, not occlusion, so it keeps the
/// bright brand coral in both modes while the fill itself deepens in dark. It is
/// applied under the fill, which is why this reaches for `reloraShadow` directly
/// rather than `reloraSurface` — the surface here is a `Circle`, already painted.
///
/// ## Reduce Motion
///
/// Handled by `reloraAnimation`, which reads the trait for us. This view never
/// asks `accessibilityReduceMotion` itself; `Motion.swift` is explicit that a
/// feature that checks it once will forget to check it somewhere else.
public struct ReloraRecordButton: View {
    private let action: () -> Void

    @State private var isPressed = false

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "mic.fill")
                // Fixed on purpose. The glyph sits inside a fixed-diameter
                // circle, so scaling the mic without scaling the circle just
                // clips it — the same reason a camera shutter does not grow
                // with Dynamic Type. The control is a shape, not text.
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(ReloraColor.onAccent)
                .frame(
                    width: ReloraFloatingLayout.recordButtonSize,
                    height: ReloraFloatingLayout.recordButtonSize
                )
                .background(
                    Circle()
                        .fill(ReloraColor.accent)
                        .reloraShadow(.accentGlow)
                )
                .scaleEffect(isPressed ? 0.94 : 1)
                .reloraAnimation(.spring, value: isPressed)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Record a note")
        .accessibilityHint("Opens the voice composer")
        // A press gesture rather than the style's `isPressed`, so the scale can
        // spring back after the sheet is already on its way up.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}
