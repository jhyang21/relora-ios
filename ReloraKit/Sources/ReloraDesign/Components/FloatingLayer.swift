import SwiftUI

/// The floating layer: the record button that sits over scrolling content, and
/// the toast that has to sit above it.
///
/// ## Why these numbers are not the RN numbers
///
/// `Spacing.swift` left these metrics out on purpose, noting that RN derives
/// them from a safe-area inset handed down through context:
///
/// ```
/// getFloatingBottomOffset(bottomInset) = max(bottomInset, lg) + sm
/// getToastBottomOffset(bottomInset, h) = getFloatingBottomOffset(bottomInset)
///                                        + (h > 0 ? h + sm : 0)
/// ```
///
/// SwiftUI does not need the first line. `safeAreaInset(edge:.bottom)` places
/// content above the home indicator itself and, more importantly, shrinks the
/// safe area of everything underneath — so a `List` or `ScrollView` stops
/// scrolling its last row under the record button without anyone computing a
/// content inset. `reloraFloatingActions` below is that call. What remains from
/// RN is the second line, and its reason: **a toast must clear the floating
/// actions, or the Undo it carries sits under the record button and cannot be
/// tapped.**
///
/// The RN version measured the toast against a measured action height. Here the
/// action row is a fixed size, so the clearance is a constant and nothing needs
/// measuring. That is a deliberate simplification, not an oversight — if a
/// screen ever grows a floating action of a different height, it passes its own
/// `clearance` to `reloraToastLayer`.
public enum ReloraFloatingLayout {
    /// 60 — the record button's diameter, mid-band of the 56–64 the design
    /// direction allows. Comfortably past the 44pt minimum target without
    /// becoming the loudest thing on a quiet screen.
    public static let recordButtonSize: CGFloat = 60

    /// Breathing room above and below the floating action row.
    public static let actionRowVerticalPadding: CGFloat = ReloraSpacing.sm

    /// What the floating action row reserves at the bottom of a screen.
    public static var actionRowHeight: CGFloat {
        recordButtonSize + actionRowVerticalPadding * 2
    }

    /// Gap between a toast and whatever floats below it.
    public static let toastGap: CGFloat = ReloraSpacing.sm

    /// Bottom clearance a toast needs on a screen that carries floating actions.
    public static var toastClearanceOverActions: CGFloat {
        actionRowHeight + toastGap
    }
}

public extension View {
    /// Pins content to the bottom of the screen as a floating action layer, and
    /// reserves its height so scrolling content underneath can still reach its
    /// last row.
    ///
    /// The reservation is the whole point. An `overlay`-based floating button
    /// covers the final list row; this does not.
    func reloraFloatingActions<Actions: View>(
        @ViewBuilder _ actions: () -> Actions
    ) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            actions()
                .padding(.vertical, ReloraFloatingLayout.actionRowVerticalPadding)
        }
    }
}
