import CoreGraphics
import LintelKit
import Testing

@testable import WindowsPlugin

/// `TilingTree.adopt`: a resize by hand becomes weights (pure).
@Suite(.timeLimit(.minutes(1))) struct TilingUserResizeTests {
    private func tiles(_ tree: TilingTree) -> [WindowID: CGRect] {
        TilingLayout.frames(tree, area: screen, gaps: .none)
    }

    private func shares(_ container: TilingContainer) -> [Double] {
        let total = container.totalWeight
        return container.children.map { $0.weight / total }
    }

    /// Drags `edge` of window `number` by `dx`/`dy` and returns the tiles after the tree adopted it.
    private func dragged(
        _ layout: inout TilingTree, _ number: UInt32, left: CGFloat = 0, right: CGFloat = 0, top: CGFloat = 0,
        bottom: CGFloat = 0
    ) -> (changed: Bool, tiles: [WindowID: CGRect]) {
        let before = tiles(layout)
        let tile = before[win(number)] ?? .zero
        let frame = CGRect(
            x: tile.minX + left, y: tile.minY + top, width: tile.width - left + right,
            height: tile.height - top + bottom)
        let changed = layout.adopt(frame: frame, of: win(number), tiles: before)
        return (changed, tiles(layout))
    }

    @Test func theRightEdgeOfTheFirstOfThreeColumnsTakesEqualPartsFromTheOthers() {
        var layout = tree(.horizontal, [leaf(1), leaf(2), leaf(3)])
        let before = tiles(layout)
        let result = dragged(&layout, 1, right: 100)
        #expect(result.changed)
        #expect(abs(result.tiles[win(1)]!.width - (before[win(1)]!.width + 100)) < 1.5)
        #expect(abs(result.tiles[win(2)]!.width - (before[win(2)]!.width - 50)) < 1.5)
        #expect(abs(result.tiles[win(3)]!.width - (before[win(3)]!.width - 50)) < 1.5)
        #expect(abs(layout.root.totalWeight - 3) < 1e-9)
    }

    @Test func theLeftEdgeOfTheMiddleColumnGivesToTheOneBefore() {
        var layout = tree(.horizontal, [leaf(1), leaf(2), leaf(3)])
        let before = tiles(layout)
        let result = dragged(&layout, 2, left: 60)
        #expect(result.changed)
        #expect(abs(result.tiles[win(2)]!.width - (before[win(2)]!.width - 60)) < 1.5)
        #expect(abs(result.tiles[win(1)]!.width - (before[win(1)]!.width + 60)) < 1.5)
        #expect(abs(result.tiles[win(3)]!.width - before[win(3)]!.width) < 1.5)
    }

    @Test func aNestedContainerResizesInsideItselfAndAcrossItsParent() {
        var layout = tree(.horizontal, [leaf(1), box(.vertical, [leaf(2), leaf(3)])])
        let before = tiles(layout)
        let down = dragged(&layout, 2, bottom: 50)
        #expect(down.changed)
        #expect(abs(down.tiles[win(2)]!.height - (before[win(2)]!.height + 50)) < 1.5)
        #expect(abs(down.tiles[win(3)]!.height - (before[win(3)]!.height - 50)) < 1.5)
        // The column's own width is untouched by a vertical drag.
        #expect(abs(down.tiles[win(2)]!.width - before[win(2)]!.width) < 1.5)
        // Its left edge belongs to the parent: the column grows, window 1 shrinks.
        let left = dragged(&layout, 2, left: -80)
        #expect(left.changed)
        #expect(abs(left.tiles[win(2)]!.width - (before[win(2)]!.width + 80)) < 1.5)
        #expect(abs(left.tiles[win(1)]!.width - (before[win(1)]!.width - 80)) < 1.5)
        #expect(abs(left.tiles[win(3)]!.width - left.tiles[win(2)]!.width) < 1.5)
    }

    @Test func aDragFarBeyondTheMinimumShareStopsAtIt() {
        var layout = tree(.horizontal, [leaf(1), leaf(2), leaf(3)])
        let result = dragged(&layout, 1, right: 5_000)
        #expect(result.changed)
        let floor = TilingTree.minimumShare(siblings: 3)
        for share in shares(layout.root) { #expect(share >= floor - 1e-9) }
        #expect(abs(shares(layout.root).reduce(0, +) - 1) < 1e-9)
        #expect(abs(shares(layout.root)[1] - floor) < 1e-9)
    }

    @Test func shrinkingBelowTheMinimumShareStopsAtIt() {
        var layout = tree(.horizontal, [leaf(1), leaf(2)])
        let result = dragged(&layout, 1, right: -5_000)
        #expect(result.changed)
        #expect(abs(shares(layout.root)[0] - TilingTree.minimumShare(siblings: 2)) < 1e-9)
    }

    @Test func anOuterEdgeWithNoSiblingIsIgnored() {
        var layout = tree(.horizontal, [leaf(1), leaf(2)])
        let original = layout
        let first = dragged(&layout, 1, left: -100)
        let last = dragged(&layout, 2, right: 100)
        let top = dragged(&layout, 1, top: -50)
        #expect(!first.changed && !last.changed && !top.changed)
        #expect(layout == original)
    }

    @Test func aMoveWithoutASizeChangeIsNotAResize() {
        var layout = tree(.horizontal, [leaf(1), leaf(2)])
        let original = layout
        let before = tiles(layout)
        let tile = before[win(1)]!
        let adopted = layout.adopt(frame: tile.offsetBy(dx: 120, dy: 40), of: win(1), tiles: before)
        #expect(!adopted)
        #expect(layout == original)
    }

    @Test func aDifferenceWithinTheThresholdIsIgnored() {
        var layout = tree(.horizontal, [leaf(1), leaf(2)])
        let small = dragged(&layout, 1, right: 4)
        let enough = dragged(&layout, 1, right: 6)
        #expect(!small.changed)
        #expect(enough.changed)
    }

    @Test func aWindowOutsideTheTreeChangesNothing() {
        var layout = tree(.horizontal, [leaf(1), leaf(2)])
        let before = tiles(layout)
        let adopted = layout.adopt(frame: screen, of: win(9), tiles: before)
        #expect(!adopted)
    }

    @Test func theAdoptedWeightsSurviveAStateRoundTrip() throws {
        var layout = tree(.horizontal, [leaf(1), leaf(2), leaf(3)])
        _ = dragged(&layout, 1, right: 100)
        let strategy = TilingStrategy()
        let stored = try #require(strategy.encode(AnyLayoutState(layout)))
        let restored = try #require(strategy.decode(stored)?.as(TilingTree.self))
        #expect(shares(restored.root).count == 3)
        for (a, b) in zip(shares(restored.root), shares(layout.root)) { #expect(abs(a - b) < 1e-9) }
    }
}
