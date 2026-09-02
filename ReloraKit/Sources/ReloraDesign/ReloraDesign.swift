/// # ReloraDesign
///
/// The design tokens every Relora screen is built from, and the SwiftUI
/// components built on those tokens.
///
/// Relora should feel like a personal notebook, not a CRM: warm paper, white
/// cards, a soft coral warmth, generous corners, and motion short enough that
/// you notice the result rather than the animation. This module is where that
/// feeling is written down as values, so it survives contact with twenty screens
/// written by different hands.
///
/// ## The files
///
/// - ``ReloraColor`` (`Palette.swift`) — semantic colors, light and dark, with
///   the computed WCAG contrast ratio recorded beside every text pairing.
/// - ``ReloraFont`` (`Typography.swift`) — DM Sans in five roles, all scaling
///   with Dynamic Type.
/// - ``ReloraSpacing`` / ``ReloraLayout`` (`Spacing.swift`) — the five-step
///   spacing scale and screen-level layout constants.
/// - ``ReloraRadius`` / ``ReloraShadow`` (`Shape.swift`) — corner radii and the
///   four elevation tiers.
/// - ``ReloraAnimation`` / ``ReloraDuration`` (`Motion.swift`) — motion tokens,
///   with Reduce Motion handled once, here.
///
/// `DesignDoc.md`, alongside these files, holds the full role table, the
/// contrast matrix, and the usage rules in one page.
///
/// ## Three rules for anyone consuming this module
///
/// 1. **Never write a literal.** No hex, no point value, no duration in a view.
///    If the token you want does not exist, add it here with a comment saying
///    why, rather than inlining it once and again somewhere else.
/// 2. **Use `accentText` for text and `accent` for fills.** The coral reaches
///    only 1.98:1 as text on a white card. `success` and `danger` are feedback
///    only — never decoration.
/// 3. **Never check `accessibilityReduceMotion` in a feature.**
///    `.reloraAnimation(_:value:)` and `withReloraAnimation(_:)` already do.
///
/// ## Both modes are first-class
///
/// The light palette is locked and mirrors the React Native app. The dark
/// palette was designed here and is not a mechanical inversion: the ground is a
/// warm near-black in the same hue family as the light ink, elevation is carried
/// by surface lightness rather than shadow, and every text-capable pairing was
/// checked arithmetically against WCAG rather than eyeballed. Build and review
/// every screen in both.
public enum ReloraDesignModule {}
