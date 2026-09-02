import SwiftUI

/// Corner radii, mirroring `radii` in `apps/mobile/src/theme/tokens.ts`.
///
/// Relora's radii are large by iOS convention. That is the point — soft corners
/// are most of what separates "notebook" from "CRM". Do not reach for a smaller
/// radius to make something look denser.
public enum ReloraRadius {
    /// 12 — small controls: chips, pills that are not fully rounded, inputs.
    public static let sm: CGFloat = 12

    /// 16 — the default surface radius. Cards, sheets, panels.
    public static let md: CGFloat = 16

    /// 20 — large cards and grouped containers.
    public static let lg: CGFloat = 20

    /// 24 — hero cards and modal sheets.
    public static let xl: CGFloat = 24

    /// Fully rounded. Buttons and the record button.
    public static let pill: CGFloat = 999
}

/// One elevation tier: a color, a blur, and an offset.
///
/// ## The dark-mode elevation principle
///
/// **In dark mode, elevation is carried by the surface, not the shadow.**
///
/// This is arithmetic, not taste. Relora's dark ground is `#1B1815`, whose
/// relative luminance is 0.0094. Compositing pure black over it barely moves
/// that number:
///
/// | Black opacity on `#1B1815` | Contrast vs ground |
/// |---|---|
/// | 10% | 1.02:1 |
/// | 20% | 1.05:1 |
/// | 28% | 1.07:1 |
/// | 32% | 1.07:1 |
///
/// For comparison, the light `card` shadow — black at *5%* on `#FAF8F5` — reaches
/// 1.11:1, and the light `floating` shadow reaches 1.25:1. There is no opacity
/// at which a black shadow on a near-black ground matches what a shadow does on
/// paper. Pushing it further only produces a smudge.
///
/// So the dark palette does the work with lightness instead: a dark `card` sits
/// **1.10:1** above the ground where a light card sits only **1.06:1** — nearly
/// double the step, chosen precisely so a card reads as raised with no shadow at
/// all. `warmCard`, `warmTintStrong` and the rest step up from `card` on the same
/// logic.
///
/// What that means per tier in dark mode:
///
/// - **`card`** drops its shadow entirely (0% opacity). A resting card already
///   sits a full step above the ground; a shadow would add nothing.
/// - **`raised`** and **`floating`** keep a shadow, at 20% and 28%. Those numbers
///   are *larger* than light mode's 6% and 10% and still produce a **weaker**
///   shadow (1.05:1 and 1.07:1, versus 1.14:1 and 1.25:1). They are there to
///   soften the edge where one elevated surface overlaps another, not to signal
///   the elevation — the surface tone does that.
/// - **`accentGlow`** is unchanged at 25% in both modes. It is emitted light
///   rather than occlusion, so it uses the bright brand coral `#FF9F8F` even in
///   dark, where the accent *fill* is the deepened `#D9877A`. The record button
///   keeps its halo, and on a dark ground it reads better than it does on paper.
///
/// The consequence for feature code: never apply a shadow tier without also
/// applying the matching surface color, or dark mode loses its only elevation
/// cue. `reloraSurface(_:radius:shadow:)` below exists to make that hard to get
/// wrong.
///
/// ## A note on the blur numbers
///
/// The radii below are taken 1:1 from the RN `shadowRadius` values, which map to
/// `CALayer.shadowRadius`. SwiftUI's `.shadow(radius:)` uses the same rough
/// convention, so the port should look right, but "should" is doing work here —
/// nobody has seen this on a device yet. Eyeball all four tiers side by side
/// against the RN build in M5 and adjust the radii (not the opacities, which are
/// derived above) if they read heavier or lighter.
public struct ReloraShadow {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat

    public init(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
    }

    /// Resting surfaces — list rows, content cards.
    ///
    /// light black 5%, y2, blur 8 · dark: no shadow, surface lift only
    public static let card = ReloraShadow(color: ReloraColor.Shadow.card, radius: 8, y: 2)

    /// Surfaces lifted off the page — menus, selected cards, a card over a card.
    ///
    /// light black 6%, y4, blur 10 · dark black 20%, y4, blur 10 (1.05:1)
    public static let raised = ReloraShadow(color: ReloraColor.Shadow.raised, radius: 10, y: 4)

    /// The floating layer — action buttons, toasts, anything over scrolling content.
    ///
    /// light black 10%, y5, blur 12 · dark black 28%, y5, blur 12 (1.07:1)
    public static let floating = ReloraShadow(color: ReloraColor.Shadow.floating, radius: 12, y: 5)

    /// The record button's halo. Coral, not black, and identical in both modes.
    ///
    /// `#FF9F8F` 25%, y14, blur 18
    public static let accentGlow = ReloraShadow(color: ReloraColor.accentGlow, radius: 18, y: 14)
}

public extension View {
    /// Applies one elevation tier.
    ///
    /// Prefer `reloraSurface(_:radius:shadow:)` for anything with a background —
    /// it keeps the shadow and the surface tone together, which is what makes
    /// dark-mode elevation work. Reach for this directly only when the surface is
    /// already painted (an image, a gradient, the record button's fill).
    func reloraShadow(_ shadow: ReloraShadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }

    /// Paints a rounded surface and its elevation together.
    ///
    /// In light mode the shadow does the lifting; in dark mode the `color` step
    /// above the ground does. Applying them as one call is what stops a feature
    /// from shipping a card that is invisible in dark mode because it took the
    /// shadow and skipped the fill.
    ///
    /// ```swift
    /// VStack { … }
    ///     .padding(ReloraSpacing.md)
    ///     .reloraSurface(ReloraColor.card, radius: ReloraRadius.md)
    /// ```
    /// The content is clipped to the corner *before* the background is drawn, so
    /// an image or a color bleeding to the edge follows the radius while the
    /// shadow still falls outside it. Clipping after the background would clip
    /// the shadow away too.
    func reloraSurface(
        _ color: Color = ReloraColor.card,
        radius: CGFloat = ReloraRadius.md,
        shadow: ReloraShadow = .card
    ) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(color)
                    .reloraShadow(shadow)
            )
    }

    /// A hairline border on a rounded surface, matching `reloraSurface`'s corner.
    func reloraBorder(
        _ color: Color = ReloraColor.hairline,
        radius: CGFloat = ReloraRadius.md,
        width: CGFloat = 1
    ) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(color, lineWidth: width)
        )
    }
}
