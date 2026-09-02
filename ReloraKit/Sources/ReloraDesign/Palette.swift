import SwiftUI
import UIKit

// MARK: - Hex plumbing

private extension UIColor {
    /// 0xRRGGBB, with an optional alpha. Kept private: features name roles, not hex.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Builds a trait-reactive `Color`.
///
/// Colors live in code rather than an asset catalog on purpose: the package stays
/// self-contained (no bundle resources, no Xcode-only editing surface) and every
/// value, along with the contrast ratio that justifies it, shows up in a diff.
private func reloraColor(
    light: UInt32,
    lightAlpha: CGFloat = 1,
    dark: UInt32,
    darkAlpha: CGFloat = 1
) -> Color {
    Color(uiColor: UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(hex: dark, alpha: darkAlpha)
            : UIColor(hex: light, alpha: lightAlpha)
    })
}

// MARK: - Palette

/// Relora's semantic colors. Roles, never raw color names — a feature asks for
/// `ReloraColor.accentText`, not "coral", so a palette change never means a
/// find-and-replace across screens.
///
/// **The light palette is locked.** Values mirror `apps/mobile/src/theme/tokens.ts`
/// and the one-off surface tints that were scattered across RN screens. Do not
/// change a light value without sign-off.
///
/// **The dark palette was designed here** (M1, 2026-08-31). Every text-capable
/// pairing below carries its computed WCAG 2.1 contrast ratio in a comment. The
/// ratios are arithmetic, not estimates: relative luminance per WCAG
/// (`L = 0.2126R + 0.7152G + 0.0722B` on linearized channels), ratio
/// `(L_lighter + 0.05) / (L_darker + 0.05)`. See `DesignDoc.md` for the full
/// matrix and the rules that govern which role goes where.
///
/// Three principles shape the dark side:
///
/// 1. **Warm all the way down.** The ground is a warm brown-gray near-black
///    (`#1B1815`), not neutral black — the same hue family as the light ink
///    `#2D2A26`. Relora is warm paper in both modes.
/// 2. **Elevation is lightness, not shadow.** A dark card sits `1.10:1` above the
///    ground where a light card sits only `1.06:1` — nearly double the step,
///    because black cannot darken a near-black ground (see `Shape.swift`).
/// 3. **Brand fills are the light values scaled 0.85 toward the ground, hue
///    preserved.** `accent`, `accentSoft`, `lavender` and `blue` are each exactly
///    85% of their light channel values, so their hue and their relationships to
///    one another survive the mode switch while the fills stop glaring.
public enum ReloraColor {

    // MARK: Surfaces

    /// App ground. Warm off-white in light; warm near-black in dark.
    ///
    /// light `#FAF8F5` · dark `#1B1815`
    public static let background = reloraColor(light: 0xFAF8F5, dark: 0x1B1815)

    /// The resting surface for content — list rows, detail panels, sheets.
    ///
    /// light `#FFFFFF` (1.06:1 above ground) · dark `#24211E` (1.10:1 above ground)
    public static let card = reloraColor(light: 0xFFFFFF, dark: 0x24211E)

    /// Warm card. The peach-tinted panel used for notices, hero cards, and the
    /// onboarding/auth/paywall blocks that want warmth without an accent fill.
    ///
    /// light `#FFF7EF` (1.06:1 above `card`) · dark `#2A2521` (1.06:1 above `card`)
    public static let warmCard = reloraColor(light: 0xFFF7EF, dark: 0x2A2521)

    /// The strongest warm surface — a warm panel that must separate from a
    /// `warmCard` sitting next to it (trial/usage banners).
    ///
    /// light `#FFF2EC` (1.10:1 above `card`) · dark `#302823` (1.11:1 above `card`)
    public static let warmTintStrong = reloraColor(light: 0xFFF2EC, dark: 0x302823)

    /// Soft highlight — the yellow-leaning warm surface for gentle, non-urgent
    /// prompts (the soft upgrade nudge).
    ///
    /// light `#FFF9EC` (1.05:1 above `card`) · dark `#2C2820` (1.09:1 above `card`)
    public static let softHighlight = reloraColor(light: 0xFFF9EC, dark: 0x2C2820)

    /// Red-leaning surface behind error content. A *surface*, not a signal —
    /// pair it with `danger` text, never use it to decorate.
    ///
    /// light `#FFF5F4` (1.07:1 above `card`) · dark `#2E211F` (1.03:1 above `card`)
    public static let dangerSurface = reloraColor(light: 0xFFF5F4, dark: 0x2E211F)

    /// Neutral context panel — the quiet, hue-free block that carries supporting
    /// text without competing with a `card`.
    ///
    /// light `#F5F2EE` (sits 1.05:1 *below* the ground, recessed) ·
    /// dark `#272524` (sits 1.16:1 *above* the ground; see the inversion note below)
    ///
    /// In dark there is no room below the ground, so a light-mode recessed neutral
    /// becomes a small upward step. It stays distinguishable from `warmCard` by
    /// hue, not by lightness: `#272524` is near-neutral (R−B spread 3) where
    /// `warmCard` is clearly warm (spread 9).
    public static let contextSurface = reloraColor(light: 0xF5F2EE, dark: 0x272524)

    /// The system/offline bar. Deliberately grayer than the warm surfaces so it
    /// reads as the app talking about itself rather than about the user's content.
    ///
    /// light `#E8E5E2` (1.18:1 vs ground) · dark `#2B2724` (1.19:1 vs ground)
    public static let offlineSurface = reloraColor(light: 0xE8E5E2, dark: 0x2B2724)

    // MARK: Ink

    /// Primary text.
    ///
    /// light `#2D2A26` · dark `#E8E1D9`
    ///
    /// Contrast — light: ground 13.47, card 14.28, warmCard 13.46,
    /// warmTintStrong 13.03, softHighlight 13.61, dangerSurface 13.34,
    /// contextSurface 12.79, offlineSurface 11.38.
    /// Dark: ground 13.64, card 12.36, warmCard 11.70, warmTintStrong 11.15,
    /// softHighlight 11.32, dangerSurface 11.97, contextSurface 11.77,
    /// offlineSurface 11.42. Minimum 11.15:1. ✔︎ AAA everywhere.
    ///
    /// The dark ink is a warm off-white, not white. It was tuned so that
    /// ink-on-ground matches light mode almost exactly (13.64 vs 13.47) rather
    /// than maximized — pure white on near-black reaches ~18:1 and halates.
    public static let ink = reloraColor(light: 0x2D2A26, dark: 0xE8E1D9)

    /// Secondary text — captions, supporting body copy, inactive labels.
    ///
    /// light `#6B6762` · dark `#A19A91`
    ///
    /// Contrast — light: ground 5.29, card 5.61, warmCard 5.29,
    /// warmTintStrong 5.12, softHighlight 5.35, dangerSurface 5.24,
    /// contextSurface 5.03, offlineSurface 4.47.
    /// Dark: ground 6.35, card 5.75, warmCard 5.45, warmTintStrong 5.19,
    /// softHighlight 5.27, dangerSurface 5.58, contextSurface 5.48,
    /// offlineSurface 5.32. Minimum 5.19:1. ✔︎ AA.
    ///
    /// Note the one light-mode gap: 4.47:1 on `offlineSurface` misses AA by 0.03.
    /// The light palette is locked, so use `ink` for text on the offline bar.
    public static let mutedInk = reloraColor(light: 0x6B6762, dark: 0xA19A91)

    /// Tertiary ink — placeholders, dividers-as-text, timestamps, disabled glyphs.
    ///
    /// light `#9B9892` · dark `#847D75`
    ///
    /// Contrast — light: 2.29–2.88 across all surfaces. **Fails AA for text.**
    /// Dark: 3.56–4.35 across all surfaces. **Also below 4.5:1.**
    ///
    /// This role does not meet 4.5:1 in either mode, and the light value is
    /// locked, so the rule is a usage rule: `tertiaryInk` is for decorative or
    /// duplicated information only — never the sole carrier of meaning, never an
    /// error, never a label a user must read to act. Where it must carry text,
    /// the text has to be Large (≥18pt regular / ≥14pt semibold) to clear 3:1,
    /// and dark clears that everywhere while light does not (2.29–2.88).
    ///
    /// Dark sits deliberately *higher* than its light counterpart. Thin light-on-dark
    /// glyphs bloom and lose perceived contrast, so the dark value buys back the
    /// margin the optics take away.
    public static let tertiaryInk = reloraColor(light: 0x9B9892, dark: 0x847D75)

    /// The label color for anything sitting on an `accent`, `accentSoft`,
    /// `lavender` or `blue` fill. Constant across modes — every brand fill is a
    /// light tone in both palettes, so its label stays the dark ink.
    ///
    /// both modes `#2D2A26`
    ///
    /// Contrast — light: on accent 7.21, accentSoft 8.36, lavender 8.94, blue 8.03.
    /// Dark: on accent 5.23, accentSoft 6.03, lavender 6.40, blue 5.78.
    /// Minimum 5.23:1. ✔︎ AA.
    ///
    /// This matches every RN call site, where a coral button already carries
    /// `colors.text`. Never put `ink` on a brand fill in dark mode — it inverts
    /// to warm off-white and collapses to roughly 2:1.
    public static let onAccent = reloraColor(light: 0x2D2A26, dark: 0x2D2A26)

    // MARK: Lines

    /// Hairline separators and card borders. The ink at low opacity, so it always
    /// belongs to the surface it divides.
    ///
    /// light `#2D2A26` @ 8% (1.16:1 on card) · dark `#E8E1D9` @ 10% (1.30:1 on card)
    ///
    /// Dark carries slightly more presence than light. A hairline on a dark ground
    /// loses more to display gamma and ambient glare than the same line on paper,
    /// so 8% would read as nothing.
    public static let hairline = reloraColor(
        light: 0x2D2A26, lightAlpha: 0.08,
        dark: 0xE8E1D9, darkAlpha: 0.10
    )

    // MARK: Brand

    /// The coral. **Fills only** — buttons, pills, progress bars, avatar circles,
    /// the record button. As text it reaches only 1.98:1 on `card` and 1.87:1 on
    /// `background` — use `accentText` for anything a user reads.
    ///
    /// light `#FF9F8F` · dark `#D9877A` (light × 0.85, hue unchanged)
    ///
    /// Fill visibility vs ground — light 1.87:1, dark 6.48:1. The dark fill is
    /// necessarily louder than the light one: a light-toned fill on a near-black
    /// ground cannot be quiet and still carry `onAccent` at 4.5:1. 0.85 is the
    /// point where `onAccent` keeps a comfortable 5.23:1 while the fill sheds as
    /// much heat as that constraint allows. See DesignDoc for the rejected
    /// alternative (a deep terracotta fill carrying light ink).
    public static let accent = reloraColor(light: 0xFF9F8F, dark: 0xD9877A)

    /// The peach. The accent's softer companion — gradient partner, secondary
    /// fills, decorative circles. Fills only, same as `accent`.
    ///
    /// light `#FFB4A2` · dark `#D9998A` (light × 0.85, hue unchanged)
    ///
    /// `onAccent` on it — light 8.36:1, dark 6.03:1. ✔︎ AA.
    public static let accentSoft = reloraColor(light: 0xFFB4A2, dark: 0xD9998A)

    /// Text-grade coral. **The only accent-colored value allowed on text.**
    ///
    /// light `#AF4A26` · dark `#D48E7B`
    ///
    /// Contrast — light: ground 5.17, card 5.48, warmCard 5.17,
    /// warmTintStrong 5.00, softHighlight 5.23, dangerSurface 5.12,
    /// contextSurface 4.91, offlineSurface 4.37.
    /// Dark: ground 6.70, card 6.07, warmCard 5.74, warmTintStrong 5.47,
    /// softHighlight 5.56, dangerSurface 5.88, contextSurface 5.78,
    /// offlineSurface 5.61. Minimum 5.47:1. ✔︎ AA.
    ///
    /// The light value is a deep burnt coral because it has to survive on white.
    /// Inverting that logic, the dark value is a *lighter, peach-leaning* coral —
    /// `#AF4A26` on `#1B1815` would be about 1.9:1, unreadable. It was tuned to
    /// land just above the light-mode band (5.47–6.70 vs 4.37–5.48) rather than
    /// as bright as possible: a 9:1 accent text would shout on a dark screen and
    /// Relora is meant to be quiet.
    ///
    /// The one light-mode gap: 4.37:1 on `offlineSurface`, 0.13 short of AA. The
    /// light palette is locked; do not put accent text on the offline bar.
    public static let accentText = reloraColor(light: 0xAF4A26, dark: 0xD48E7B)

    /// Lavender. Decorative fill only (onboarding circles, step glyph backgrounds).
    ///
    /// light `#D4C5F9` · dark `#B4A7D4` (light × 0.85, hue unchanged)
    ///
    /// `onAccent` on it — light 8.94:1, dark 6.40:1. ✔︎ AA.
    public static let lavender = reloraColor(light: 0xD4C5F9, dark: 0xB4A7D4)

    /// Blue. Decorative fill only, the cool counterweight to the coral.
    ///
    /// light `#A8C5E8` · dark `#8FA7C5` (light × 0.85, hue unchanged)
    ///
    /// `onAccent` on it — light 8.03:1, dark 5.78:1. ✔︎ AA.
    public static let blue = reloraColor(light: 0xA8C5E8, dark: 0x8FA7C5)

    // MARK: Accent tints

    /// A wash of the accent — the faint coral fill behind a selected row or an
    /// accent-flavored panel.
    ///
    /// light `accent` @ 12% (1.09:1 on card) · dark `accent` @ 10% (1.17:1 on card)
    ///
    /// This and `accentTintBorder` replace the six different coral alphas
    /// (0.08 / 0.12 / 0.14 / 0.16 / 0.20 / 0.24) scattered across RN screens.
    /// If a feature in M2+ genuinely needs a third step, add it here rather than
    /// re-introducing a one-off.
    public static let accentTintFill = reloraColor(
        light: 0xFF9F8F, lightAlpha: 0.12,
        dark: 0xD9877A, darkAlpha: 0.10
    )

    /// The accent as a border — an outlined chip, a selected card's edge.
    ///
    /// light `accent` @ 20% (1.14:1 on card) · dark `accent` @ 16% (1.30:1 on card)
    ///
    /// The dark presence matches `hairline` exactly (both 1.30:1), so an accented
    /// border and a plain one weigh the same and differ only in hue.
    public static let accentTintBorder = reloraColor(
        light: 0xFF9F8F, lightAlpha: 0.20,
        dark: 0xD9877A, darkAlpha: 0.16
    )

    /// The record button's halo. Not a shadow — emitted light, so it keeps the
    /// **bright** brand coral in both modes rather than the deepened dark fill.
    ///
    /// both modes `#FF9F8F` @ 25%
    ///
    /// Consumed by `ReloraShadow.accentGlow`; features should reach for that tier,
    /// not this color.
    public static let accentGlow = reloraColor(
        light: 0xFF9F8F, lightAlpha: 0.25,
        dark: 0xFF9F8F, darkAlpha: 0.25
    )

    // MARK: Feedback

    /// Success. **Feedback only** — confirmations and toasts. Never decorative,
    /// never a brand color, never a chart fill.
    ///
    /// light `#2F8A57` · dark `#57B681`
    ///
    /// Contrast — light: ground 4.05, card 4.29, warmCard 4.05,
    /// warmTintStrong 3.92, softHighlight 4.09, dangerSurface 4.01,
    /// contextSurface 3.85, offlineSurface 3.42. **Fails AA (4.5:1) on every
    /// light surface**; it clears 3:1, so light-mode success text must be Large
    /// (≥18pt regular / ≥14pt semibold) or pair the color with an icon and
    /// `ink`-colored wording. The light value is locked — flagged for review.
    ///
    /// Dark: ground 7.08, card 6.42, warmCard 6.07, warmTintStrong 5.79,
    /// softHighlight 5.88, dangerSurface 6.22, contextSurface 6.11,
    /// offlineSurface 5.93. Minimum 5.79:1. ✔︎ AA at any size.
    public static let success = reloraColor(light: 0x2F8A57, dark: 0x57B681)

    /// Danger. **Feedback only** — errors, destructive confirmations, validation.
    ///
    /// light `#B44A3D` · dark `#E97469`
    ///
    /// Contrast — light: ground 4.97, card 5.27, warmCard 4.97,
    /// warmTintStrong 4.81, softHighlight 5.02, dangerSurface 4.92,
    /// contextSurface 4.72, offlineSurface 4.20.
    /// Dark: ground 6.03, card 5.47, warmCard 5.17, warmTintStrong 4.93,
    /// softHighlight 5.01, dangerSurface 5.30, contextSurface 5.21,
    /// offlineSurface 5.05. Dark minimum 4.93:1. ✔︎ AA.
    ///
    /// Light misses AA only on `offlineSurface` (4.20:1) — do not put error text
    /// on the offline bar.
    ///
    /// The dark value is held apart from the coral by hue, not lightness. Light
    /// mode separates them easily (danger G/R 0.41 vs accent G/R 0.62); the dark
    /// danger keeps G/R at 0.50 against the dark accent's 0.62, so a red toast
    /// never reads as a brand element. Unlike light mode the dark danger is
    /// *brighter* than the dark accent — on a dark ground an error has to come
    /// forward, and the hue gap carries the distinction.
    public static let danger = reloraColor(light: 0xB44A3D, dark: 0xE97469)

    // MARK: Shadow inks

    /// Shadow colors backing `ReloraShadow`. Features use the shadow tiers in
    /// `Shape.swift`; these exist so the opacities live beside the rest of the
    /// palette. See `Shape.swift` for why dark uses larger opacity numbers to
    /// produce a *weaker* shadow.
    public enum Shadow {
        /// light black @ 5% · dark black @ 0% (no shadow; the surface step carries it)
        public static let card = reloraColor(
            light: 0x000000, lightAlpha: 0.05,
            dark: 0x000000, darkAlpha: 0.0
        )

        /// light black @ 6% (1.14:1 on ground) · dark black @ 20% (1.05:1 on ground)
        public static let raised = reloraColor(
            light: 0x000000, lightAlpha: 0.06,
            dark: 0x000000, darkAlpha: 0.20
        )

        /// light black @ 10% (1.25:1 on ground) · dark black @ 28% (1.07:1 on ground)
        public static let floating = reloraColor(
            light: 0x000000, lightAlpha: 0.10,
            dark: 0x000000, darkAlpha: 0.28
        )
    }
}
