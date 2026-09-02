import SwiftUI

/// The row-breaking arithmetic behind ``ReloraFlowLayout``.
///
/// Split out from the `Layout` conformance because `LayoutSubviews` cannot be
/// constructed in a test — the geometry is the part worth pinning, and this way
/// it can be exercised with plain `CGSize`s.
///
/// Origins are relative to the container's top-leading corner; the layout adds
/// `bounds.origin` when it places.
struct ReloraFlowSolver {
    struct Placement: Equatable {
        let index: Int
        let origin: CGPoint
    }

    struct Solution: Equatable {
        let placements: [Placement]
        let size: CGSize
    }

    /// Packs `sizes` into rows no wider than `maxWidth`, breaking left to right.
    ///
    /// An item wider than `maxWidth` on its own does not break onto an empty row
    /// — it overflows the one it starts. Breaking it would loop forever, and at
    /// accessibility text sizes a single pill genuinely can exceed the container.
    static func solve(
        sizes: [CGSize],
        maxWidth: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat
    ) -> Solution {
        var placements: [Placement] = []
        var rowStart = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for (index, size) in sizes.enumerated() {
            let isFirstInRow = index == rowStart
            if !isFirstInRow, x + horizontalSpacing + size.width > maxWidth {
                widest = max(widest, x)
                y += rowHeight + verticalSpacing
                x = 0
                rowHeight = 0
                rowStart = index
            }

            let originX = index == rowStart ? 0 : x + horizontalSpacing
            placements.append(Placement(index: index, origin: CGPoint(x: originX, y: y)))
            x = originX + size.width
            rowHeight = max(rowHeight, size.height)
        }

        widest = max(widest, x)
        return Solution(
            placements: placements,
            size: CGSize(width: widest, height: y + rowHeight)
        )
    }
}

/// A wrapping row of views — RN's `flexWrap`, which SwiftUI's `HStack` has no
/// equivalent for.
///
/// Exists because hand-chunking items into fixed rows ("two per row") breaks the
/// moment type scales: at accessibility sizes two pills no longer fit side by
/// side, and a fixed chunk clips rather than wraps. This measures each item at
/// the width it actually gets and breaks where it actually runs out.
///
/// ```swift
/// ReloraFlowLayout {
///     ForEach(options, id: \.self) { OnboardingPillButton(label: $0, …) }
/// }
/// ```
///
/// Items are top-aligned within their row: at large text sizes one item can wrap
/// to two lines and grow taller than its neighbours, and a shared top edge reads
/// better there than a shared centre line.
public struct ReloraFlowLayout: Layout {
    private let horizontalSpacing: CGFloat
    private let verticalSpacing: CGFloat

    public init(
        horizontalSpacing: CGFloat = ReloraSpacing.sm,
        verticalSpacing: CGFloat = ReloraSpacing.sm
    ) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let width = Self.usableWidth(proposal)
        return solution(subviews: subviews, maxWidth: width).size
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let width = Self.usableWidth(proposal) ?? bounds.width
        let sizes = Self.measure(subviews, maxWidth: width)
        let solved = ReloraFlowSolver.solve(
            sizes: sizes,
            maxWidth: width,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing
        )

        for placement in solved.placements {
            subviews[placement.index].place(
                at: CGPoint(
                    x: bounds.minX + placement.origin.x,
                    y: bounds.minY + placement.origin.y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(sizes[placement.index])
            )
        }
    }

    private func solution(subviews: Subviews, maxWidth: CGFloat?) -> ReloraFlowSolver.Solution {
        ReloraFlowSolver.solve(
            sizes: Self.measure(subviews, maxWidth: maxWidth),
            // No width proposal means nothing is constraining us, so everything
            // belongs on one row and the container reports its natural width.
            maxWidth: maxWidth ?? .greatestFiniteMagnitude,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing
        )
    }

    /// Measures each item at the width it can actually occupy, so a label too
    /// long for one row wraps its own text instead of overflowing the container.
    private static func measure(_ subviews: Subviews, maxWidth: CGFloat?) -> [CGSize] {
        let childProposal = maxWidth.map { ProposedViewSize(width: $0, height: nil) } ?? .unspecified
        return subviews.map { $0.sizeThatFits(childProposal) }
    }

    /// A proposal can carry `nil` or an infinite width; neither can bound a row.
    private static func usableWidth(_ proposal: ProposedViewSize) -> CGFloat? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return width
    }
}
