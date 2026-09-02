import CoreGraphics

/// Relora's spacing scale, mirroring `spacing` in
/// `apps/mobile/src/theme/tokens.ts`.
///
/// Five steps, and only five. A gap that is not on the scale is a bug or a new
/// token — it is never a literal in a view.
public enum ReloraSpacing {
    /// 6 — inside a control: icon to its label, chip padding.
    public static let xs: CGFloat = 6

    /// 10 — between tightly related lines, list-row vertical padding.
    public static let sm: CGFloat = 10

    /// 16 — the default. Card padding, gap between fields.
    public static let md: CGFloat = 16

    /// 24 — between distinct groups inside a screen.
    public static let lg: CGFloat = 24

    /// 32 — between major sections.
    public static let xl: CGFloat = 32
}

/// Screen-level layout constants, mirroring `apps/mobile/src/theme/layout.ts`.
public enum ReloraLayout {
    /// 28 — horizontal inset for screen content. Wider than `ReloraSpacing.lg`
    /// on purpose: the generous margin is a large part of why Relora reads as a
    /// notebook rather than a dense tool. Do not substitute `lg` for it.
    public static let screenHPadding: CGFloat = 28

    /// 560 — content stops widening here and centers. Keeps line length readable
    /// on iPad and on a landscape Max-class phone.
    public static let contentMaxWidth: CGFloat = 560

    // MARK: Floating-layer metrics — defined in FloatingLayer.swift, not here
    //
    // RN derives the floating-action and toast offsets from the live safe-area
    // inset, not from constants (`apps/mobile/src/theme/layout.ts`):
    //
    //   getFloatingBottomOffset(bottomInset)  = max(bottomInset, lg) + sm
    //   getToastBottomOffset(bottomInset, h)  = getFloatingBottomOffset(bottomInset)
    //                                           + (h > 0 ? h + sm : 0)
    //   getOverlayContentBottomPadding(i, h)  = getFloatingBottomOffset(i) + h
    //   getScreenTopPadding(topInset)         = topInset + md
    //
    // SwiftUI reads the inset differently from React Native (safeAreaInset and
    // the safe-area container modifiers, not a number handed down through
    // context), so porting these as free functions taking a `bottomInset` would
    // bake in the wrong shape. They were left out of this file until the
    // milestone that built the floating record button and the toast layer;
    // `Components/FloatingLayer.swift` (`ReloraFloatingLayout`) is where that
    // API landed, expressing the first two formulas in SwiftUI's own terms.
    // The last two have no SwiftUI counterpart yet — safe-area modifiers cover
    // their cases so far — and this table remains their RN reference.
    //
    // One constraint from RN worth carrying forward: the toast layer must clear
    // the floating actions. In RN a toast that sits under the FAB swallows the
    // Undo that restores a deleted item — the reason `getToastBottomOffset`
    // takes a height at all.
}
