import SwiftUI
import UIKit

/// Relora's type scale: DM Sans in semantic roles, every role scaling with
/// Dynamic Type.
///
/// ## Roles, and where they come from
///
/// The RN app has four sizes (`typography` in `apps/mobile/src/theme/tokens.ts`).
/// Native needs a fifth for screen titles that RN faked with an oversized heading:
///
/// | Role         | Size / weight    | `relativeTo`  | RN equivalent      |
/// |--------------|------------------|---------------|--------------------|
/// | `largeTitle` | 34 Bold          | `.largeTitle` | — (new)            |
/// | `title`      | 28 SemiBold      | `.title`      | `typography.heading` |
/// | `title3`     | 22 SemiBold      | `.title3`     | `typography.title` |
/// | `body`       | 15 Regular       | `.body`       | `typography.body`  |
/// | `listBody`   | 17 Regular       | `.body`       | — (new)            |
/// | `footnote`   | 13 Medium        | `.footnote`   | `typography.label` |
///
/// ## Dynamic Type
///
/// Every role uses `Font.custom(_:size:relativeTo:)`, which anchors the custom
/// face to a system text style and scales it with the user's setting. Never use
/// the two-argument `Font.custom(_:size:)` — it produces a fixed size that
/// ignores accessibility entirely.
///
/// Because the sizes scale, do not pin heights on text containers. Let them grow.
///
/// ## Fonts are not in this package
///
/// The TTFs ship in the **app** bundle and are registered in the app's Info.plist
/// (`UIAppFonts`) in M5. A Swift package target cannot register fonts for the host
/// app, so `ReloraDesign` names the faces and the app supplies them.
///
/// ### If the fonts are missing
///
/// `Font.custom` with an unregistered name does not crash or draw blank — SwiftUI
/// silently substitutes the system font at the same size, still Dynamic-Type
/// scaled. That is an acceptable failure: the app stays usable and legible, it
/// just looks wrong. Because the failure is silent, `assertFontsAvailable()` below
/// exists to make it loud during development.
public enum ReloraFont {

    /// PostScript names, which are what `Font.custom` matches against — **not**
    /// filenames and not the family name "DM Sans".
    ///
    /// These are the standard PostScript names for the Google Fonts DM Sans
    /// static instances. They are an assumption until the TTFs land in M5:
    /// whoever adds the files must confirm each one (Font Book → the font's
    /// PostScript name, or `CTFontManagerCreateFontDescriptorsFromURL`) and fix
    /// these constants if a face reports something else. A variable-font build of
    /// DM Sans, for instance, exposes a single `DMSans-Regular` face and none of
    /// the other three, which would silently fall back to system for every
    /// non-regular role.
    public enum Name {
        public static let regular = "DMSans-Regular"
        public static let medium = "DMSans-Medium"
        public static let semiBold = "DMSans-SemiBold"
        public static let bold = "DMSans-Bold"

        /// Every face the design system expects to find. Used by
        /// `assertFontsAvailable()`.
        public static let all = [regular, medium, semiBold, bold]
    }

    /// Screen-level titles. 34 Bold.
    public static let largeTitle = Font.custom(Name.bold, size: 34, relativeTo: .largeTitle)

    /// Section headings and hero copy. 28 SemiBold. (RN `typography.heading`.)
    public static let title = Font.custom(Name.semiBold, size: 28, relativeTo: .title)

    /// Card titles and sub-headings. 22 SemiBold. (RN `typography.title`.)
    public static let title3 = Font.custom(Name.semiBold, size: 22, relativeTo: .title3)

    /// Body copy — the default for anything a user reads at length. 15 Regular.
    public static let body = Font.custom(Name.regular, size: 15, relativeTo: .body)

    /// Form and list row titles and values. 17 Regular — the system row metric.
    /// `body` (15) is Relora's reading size and sits visibly small in a native row.
    public static let listBody = Font.custom(Name.regular, size: 17, relativeTo: .body)

    /// Labels, captions, eyebrows, timestamps. 13 Medium. (RN `typography.label`.)
    ///
    /// Medium rather than Regular on purpose: at 13pt the extra weight is what
    /// keeps `mutedInk` legible, and several of these labels sit at the 5.19:1
    /// floor of that role.
    public static let footnote = Font.custom(Name.medium, size: 13, relativeTo: .footnote)

    /// Names of any expected DM Sans faces the process cannot resolve.
    ///
    /// Empty means all four registered. A non-empty result means those roles are
    /// silently rendering in the system font.
    ///
    /// Call it once at launch behind `#if DEBUG` so a missing or misnamed TTF
    /// fails loudly in development instead of shipping as "the type looks a bit
    /// off". It is intentionally not an `assert` itself — the caller decides
    /// whether to trap, log, or surface it in a debug menu.
    public static func missingFontNames() -> [String] {
        Name.all.filter { UIFont(name: $0, size: 12) == nil }
    }

    /// Debug-only tripwire for the M5 font drop. No-op in release.
    public static func assertFontsAvailable(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        #if DEBUG
        let missing = missingFontNames()
        assert(
            missing.isEmpty,
            """
            ReloraDesign: DM Sans faces not registered: \(missing.joined(separator: ", ")).
            Add the TTFs to the app target and list them under UIAppFonts in Info.plist, \
            then confirm each PostScript name against ReloraFont.Name.
            """,
            file: file,
            line: line
        )
        #endif
    }
}
