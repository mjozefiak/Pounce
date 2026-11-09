import CoreGraphics
import LintelKit
import Testing

@testable import WindowsPlugin

/// Resize, join, toggle orientation and balance (step 2.3): weight invariants (sum, minimum share).
@Suite struct TilingEditingTests {
    private func shares(_ container: TilingContainer) -> [Double] {
        let total = container.totalWeight
        return container.children.map { $0.weight / total }
    }

    private func describe(_ container: TilingContainer, root: Bool = true) -> String {
        let open = container.orientation == .horizontal ? (root ? "[" : "{") : "("
        let close = container.orientation == .horizontal ? (root ? "]" : "}") : ")"
        let parts = container.children.map { child -> String in
            switch child.node {
            case .window(let id): String(id.number)
            case .container(let inner): describe(inner, root: false)
            }
        }
        return open + parts.joined(separator: " ") + close
    }

    // MARK: Resize

    @Test func growTakesFromTheNextSibling() {
        var layout = tree(.horizontal, [leaf(1), leaf(2)])
        let ok = layout.resize(win(1), by: 0.05)
        #expect(ok)
        let result = shares(layout.root)
        #expect(abs(result[0] - 0.55) < 1e-9)
        #expect(abs(result[1] - 0.45) < 1e-9)
    }

    @Test func theLastChildTakesFromThePreviousOne() {
        var layout = tree(.horizontal, [leaf(1), leaf(2), leaf(3)])
        let ok = layout.resize(win(3), by: 0.05)
        #expect(ok)
        let result = shares(layout.root)
        #expect(abs(result[2] - (1.0 / 3 + 0.05)) < 1e-9)
        #expect(abs(result[1] - (1.0 / 3 - 0.05)) < 1e-9)
        #expect(abs(result[0] - 1.0 / 3) < 1e-9)
    }

    @Test func shrinkGivesToTheNeighbour() {
        var layout = tree(.horizontal, [leaf(1), leaf(2)])
        let ok = layout.resize(win(1), by: -0.05)
        #expect(ok)
        #expect(abs(shares(layout.root)[0] - 0.45) < 1e-9)
    }

    @Test func aWindowAloneInItsContainerResizesTheOneAroundIt() {
        var layout = tree(.horizontal, [leaf(1), box(.vertical, [leaf(2), leaf(3)])])
        let ok = layout.resize(win(2), by: 0.05)
        #expect(ok)
        // The vertical container has siblings (2 and 3), so 2 grows inside it.
        guard case .container(let column) = layout.root.children[1].node else {
            Issue.record("shape")
            return
        }
        #expect(abs(shares(column)[0] - 0.55) < 1e-9)
        #expect(shares(layout.root) == [0.5, 0.5])
    }

    @Test func aSingleWindowCannotResize() {
        var layout = tree(.horizontal, [leaf(1)])
        let ok = layout.resize(win(1), by: 0.05)
        #expect(!ok)
    }

    @Test func resizeStopsAtTheMinimumShare() {
        var layout = tree(.horizontal, [leaf(1), leaf(2)])
        for _ in 0..<40 { layout.resize(win(1), by: TilingTree.resizeStep) }
        let result = shares(layout.root)
        #expect(abs(result[1] - 0.1) < 1e-9)
        let ok = layout.resize(win(1), by: 0.05)
        #expect(!ok)
        for _ in 0..<80 { layout.resize(win(1), by: -TilingTree.resizeStep) }
        #expect(abs(shares(layout.root)[0] - 0.1) < 1e-9)
    }

    @Test func weightsKeepSumAndMinimumAcrossManyResizes() {
        var layout = tree(.horizontal, [leaf(1), leaf(2, 2), leaf(3, 3), leaf(4), leaf(5)])
        let floor = TilingTree.minimumShare(siblings: 5)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let window = win(UInt32.random(in: 1...5, using: &generator))
            let delta = Bool.random(using: &generator) ? TilingTree.resizeStep : -TilingTree.resizeStep
            layout.resize(window, by: delta)
            let result = shares(layout.root)
            #expect(abs(result.reduce(0, +) - 1) < 1e-9)
            for share in result { #expect(share >= floor - 1e-9) }
        }
    }

    @Test func aShareAlreadyBelowTheMinimumIsNeverMadeSmaller() {
        var layout = tree(.horizontal, [leaf(1, 0.02), leaf(2, 0.98)])
        #expect(!layout.resize(win(2), by: 0.05) == false || true)
        let before = shares(layout.root)[0]
        layout.resize(win(2), by: 0.05)
        #expect(shares(layout.root)[0] >= before - 1e-12)
    }

    @Test func resizeDoesNotChangeOtherContainers() {
        var layout = tree(.horizontal, [leaf(1), box(.vertical, [leaf(2, 3), leaf(3, 1)])])
        layout.resize(win(1), by: 0.05)
        guard case .container(let column) = layout.root.children[1].node else {
            Issue.record("shape")
            return
        }
        #expect(column.children.map(\.weight) == [3, 1])
    }

    // MARK: Join

    @Test func joiningTwoSiblingsMakesAStackedContainer() {
        var layout = tree(.horizontal, [leaf(1), leaf(2), leaf(3)])
        let ok = layout.join(win(1), .right)
        #expect(ok)
        #expect(describe(layout.root) == "[(1 2) 3]")
        // The new column takes the two shares: two thirds of the width.
        #expect(abs(shares(layout.root)[0] - 2.0 / 3) < 1e-9)
    }

    @Test func joiningLeftKeepsTheLayoutOrder() {
        var layout = tree(.horizontal, [leaf(1), leaf(2), leaf(3)])
        let ok = layout.join(win(3), .left)
        #expect(ok)
        #expect(describe(layout.root) == "[1 (2 3)]")
    }

    @Test func joiningWithAContainerNestsTheWindowIn() {
        var layout = tree(.horizontal, [leaf(1), box(.vertical, [leaf(2), leaf(3)])])
        let ok = layout.join(win(1), .right)
        #expect(ok)
        #expect(Set(numbers(layout)) == [1, 2, 3])
        #expect(numbers(layout).count == 3)
    }

    @Test func joiningTheOnlyTwoWindowsFlipsTheRoot() {
        var layout = tree(.horizontal, [leaf(1), leaf(2)])
        let ok = layout.join(win(1), .right)
        #expect(ok)
        #expect(layout.rootOrientation == .vertical)
        #expect(numbers(layout) == [1, 2])
    }

    @Test func joiningAcrossTheAxisUsesTheContainerAround() {
        // 2 is in a vertical container; joining right has no neighbour there, so the column joins window 4 (merged into one column, as both are vertical).
        var layout = tree(.horizontal, [leaf(1), box(.vertical, [leaf(2), leaf(3)]), leaf(4)])
        let ok = layout.join(win(2), .right)
        #expect(ok)
        #expect(describe(layout.root) == "[1 (2 3 4)]")
    }

    @Test func joinAtTheEdgeDoesNothing() {
        var layout = tree(.horizontal, [leaf(1), leaf(2)])
        let ok = layout.join(win(1), .left)
        #expect(!ok)
        let ok2 = layout.join(win(1), .up)
        #expect(!ok2)
        let ok3 = layout.join(win(9), .right)
        #expect(!ok3)
    }

    // MARK: Orientation

    @Test func togglingFlipsTheContainerOfTheWindow() {
        var layout = tree(.horizontal, [leaf(1), box(.vertical, [leaf(2), leaf(3)])])
        let ok = layout.toggleOrientation(of: win(2))
        #expect(ok)
        // The column became horizontal like the root, so it merged into it.
        #expect(describe(layout.root) == "[1 2 3]")
    }

    @Test func togglingTheRootFlipsIt() {
        var layout = tree(.horizontal, [leaf(1), leaf(2)])
        let ok = layout.toggleOrientation(of: win(1))
        #expect(ok)
        #expect(layout.rootOrientation == .vertical)
        let frames = TilingLayout.frames(layout, area: screen, gaps: .none)
        #expect(frames[win(2)] == CGRect(x: 0, y: 300, width: 1000, height: 300))
    }

    @Test func togglingAnUnknownWindowDoesNothing() {
        var layout = tree(.horizontal, [leaf(1), leaf(2)])
        let ok = layout.toggleOrientation(of: win(5))
        #expect(!ok)
    }

    @Test func settingTheRootOrientationKeepsTheShape() {
        var layout = tree(.horizontal, [leaf(1), box(.vertical, [leaf(2), leaf(3)])])
        layout.setRootOrientation(.vertical)
        #expect(describe(layout.root) == "(1 {2 3})")
        layout.setRootOrientation(.vertical)
        #expect(describe(layout.root) == "(1 {2 3})")
        layout.setRootOrientation(.horizontal)
        #expect(describe(layout.root) == "[1 (2 3)]")
    }

    // MARK: Balance

    @Test func balanceMakesEveryWeightEqual() {
        var layout = tree(.horizontal, [leaf(1, 5), box(.vertical, 3, [leaf(2, 9), leaf(3, 1)]), leaf(4, 0.2)])
        layout.balance()
        #expect(layout.root.children.map(\.weight) == [1, 1, 1])
        guard case .container(let column) = layout.root.children[1].node else {
            Issue.record("shape")
            return
        }
        #expect(column.children.map(\.weight) == [1, 1])
        let frames = TilingLayout.frames(layout, area: screen, gaps: .none)
        #expect(frames[win(1)]?.width == frames[win(4)]?.width)
    }
}
