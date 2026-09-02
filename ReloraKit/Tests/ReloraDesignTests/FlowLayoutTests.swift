import CoreGraphics
import Testing
@testable import ReloraDesign

/// Pins ``ReloraFlowSolver``'s row breaking. The `Layout` conformance around it
/// cannot be tested (`LayoutSubviews` is not constructible), so this covers the
/// arithmetic that decides where a pill lands.

private func size(_ width: CGFloat, _ height: CGFloat = 44) -> CGSize {
    CGSize(width: width, height: height)
}

private func solve(
    _ sizes: [CGSize],
    maxWidth: CGFloat,
    h: CGFloat = 10,
    v: CGFloat = 10
) -> ReloraFlowSolver.Solution {
    ReloraFlowSolver.solve(
        sizes: sizes,
        maxWidth: maxWidth,
        horizontalSpacing: h,
        verticalSpacing: v
    )
}

@Test func emptyInputProducesNothing() {
    let result = solve([], maxWidth: 300)
    #expect(result.placements.isEmpty)
    #expect(result.size == .zero)
}

@Test func itemsThatFitStayOnOneRow() {
    let result = solve([size(100), size(100), size(80)], maxWidth: 300)

    #expect(result.placements.map(\.origin.y) == [0, 0, 0])
    // 100 + 10 + 100 + 10 + 80
    #expect(result.placements.map(\.origin.x) == [0, 110, 220])
    #expect(result.size == CGSize(width: 300, height: 44))
}

@Test func overflowingItemStartsANewRow() {
    // Third item needs 220 + 10 + 100 = 330 > 300, so it wraps.
    let result = solve([size(100), size(100), size(100)], maxWidth: 300)

    #expect(result.placements.map(\.origin.x) == [0, 110, 0])
    #expect(result.placements.map(\.origin.y) == [0, 0, 54])
    // Widest row is the first (210), height is two 44pt rows plus 10pt gutter.
    #expect(result.size == CGSize(width: 210, height: 98))
}

@Test func spacingIsNotChargedToTheFirstItemInARow() {
    // Exactly filling the row: 145 + 10 + 145 = 300.
    let result = solve([size(145), size(145)], maxWidth: 300)

    #expect(result.placements.map(\.origin.y) == [0, 0])
    #expect(result.size.width == 300)
}

@Test func itemWiderThanTheRowOverflowsRatherThanLooping() {
    // A single item that cannot fit must still be placed, not pushed forever
    // onto a fresh empty row.
    let result = solve([size(500)], maxWidth: 300)

    #expect(result.placements == [ReloraFlowSolver.Placement(index: 0, origin: .zero)])
    #expect(result.size == CGSize(width: 500, height: 44))
}

@Test func oversizedItemDoesNotDragTheNextItemOntoItsRow() {
    let result = solve([size(500), size(50)], maxWidth: 300)

    #expect(result.placements.map(\.origin.y) == [0, 54])
    #expect(result.size.width == 500)
}

@Test func rowHeightFollowsTheTallestItemInThatRow() {
    // A label that wrapped to two lines makes its whole row taller.
    let result = solve([size(100, 44), size(100, 70), size(100, 44)], maxWidth: 300)

    #expect(result.placements.map(\.origin.y) == [0, 0, 80])
    #expect(result.size.height == 124)
}

@Test func everyItemGetsItsOwnRowWhenTheContainerIsNarrow() {
    let result = solve([size(90), size(90), size(90)], maxWidth: 100)

    #expect(result.placements.map(\.origin.x) == [0, 0, 0])
    #expect(result.placements.map(\.origin.y) == [0, 54, 108])
    #expect(result.size == CGSize(width: 90, height: 152))
}

@Test func indicesSurviveWrapping() {
    let result = solve(Array(repeating: size(100), count: 5), maxWidth: 300)

    #expect(result.placements.map(\.index) == [0, 1, 2, 3, 4])
}

@Test func zeroSpacingPacksItemsFlush() {
    let result = solve([size(100), size(100), size(100)], maxWidth: 300, h: 0, v: 0)

    #expect(result.placements.map(\.origin.x) == [0, 100, 200])
    #expect(result.placements.map(\.origin.y) == [0, 0, 0])
    #expect(result.size == CGSize(width: 300, height: 44))
}
