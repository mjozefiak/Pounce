import CoreGraphics
import LintelKit
import Testing

@testable import WindowsPlugin

/// The pure tiling tree and its frames (step 2.1): golden frames for nested trees and gaps.
@Suite(.timeLimit(.minutes(1))) struct TilingTreeTests {
    private func frames(_ tree: TilingTree, gaps: TilingGaps = .none, area: CGRect = screen) -> [UInt32: CGRect] {
        Dictionary(
            uniqueKeysWithValues: TilingLayout.frames(tree, area: area, gaps: gaps).map { ($0.key.number, $0.value) })
    }

    // MARK: Golden frames

    @Test func oneWindowFillsTheArea() {
        let result = frames(tree(.horizontal, [leaf(1)]))
        #expect(result == [1: screen])
    }

    @Test func twoWindowsSplitTheWidth() {
        let result = frames(tree(.horizontal, [leaf(1), leaf(2)]))
        #expect(result[1] == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(result[2] == CGRect(x: 500, y: 0, width: 500, height: 600))
    }

    @Test func aVerticalRootSplitsTheHeight() {
        let result = frames(tree(.vertical, [leaf(1), leaf(2), leaf(3)]))
        #expect(result[1] == CGRect(x: 0, y: 0, width: 1000, height: 200))
        #expect(result[2] == CGRect(x: 0, y: 200, width: 1000, height: 200))
        #expect(result[3] == CGRect(x: 0, y: 400, width: 1000, height: 200))
    }

    @Test func weightsDecideTheShares() {
        let result = frames(tree(.horizontal, [leaf(1, 3), leaf(2, 1)]))
        #expect(result[1] == CGRect(x: 0, y: 0, width: 750, height: 600))
        #expect(result[2] == CGRect(x: 750, y: 0, width: 250, height: 600))
    }

    @Test func nestedContainersSplitTheirTile() {
        let nested = tree(.horizontal, [leaf(1), box(.vertical, [leaf(2), leaf(3)])])
        let result = frames(nested)
        #expect(result[1] == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(result[2] == CGRect(x: 500, y: 0, width: 500, height: 300))
        #expect(result[3] == CGRect(x: 500, y: 300, width: 500, height: 300))
    }

    @Test func deeplyNestedGolden() {
        let nested = tree(
            .horizontal,
            [leaf(1, 2), box(.vertical, 1, [leaf(2), box(.horizontal, 1, [leaf(3), leaf(4)])])])
        let result = frames(nested)
        #expect(result[1] == CGRect(x: 0, y: 0, width: 667, height: 600))
        #expect(result[2] == CGRect(x: 667, y: 0, width: 333, height: 300))
        #expect(result[3] == CGRect(x: 667, y: 300, width: 167, height: 300))
        #expect(result[4] == CGRect(x: 834, y: 300, width: 166, height: 300))
    }

    @Test func innerGapsSeparateNeighbours() {
        let result = frames(tree(.horizontal, [leaf(1), leaf(2)]), gaps: TilingGaps(inner: 10, outer: 0))
        #expect(result[1] == CGRect(x: 0, y: 0, width: 495, height: 600))
        #expect(result[2] == CGRect(x: 505, y: 0, width: 495, height: 600))
    }

    @Test func outerGapsInsetTheArea() {
        let result = frames(tree(.horizontal, [leaf(1)]), gaps: TilingGaps(inner: 0, outer: 20))
        #expect(result[1] == CGRect(x: 20, y: 20, width: 960, height: 560))
    }

    @Test func innerAndOuterGapsOnANestedTree() {
        let nested = tree(.horizontal, [leaf(1), box(.vertical, [leaf(2), leaf(3)])])
        let result = frames(nested, gaps: TilingGaps(inner: 8, outer: 8))
        #expect(result[1] == CGRect(x: 8, y: 8, width: 488, height: 584))
        #expect(result[2] == CGRect(x: 504, y: 8, width: 488, height: 288))
        #expect(result[3] == CGRect(x: 504, y: 304, width: 488, height: 288))
    }

    @Test func anOffsetAreaKeepsItsOrigin() {
        let area = CGRect(x: 1920, y: 25, width: 800, height: 400)
        let result = frames(tree(.horizontal, [leaf(1), leaf(2)]), area: area)
        #expect(result[1] == CGRect(x: 1920, y: 25, width: 400, height: 400))
        #expect(result[2] == CGRect(x: 2320, y: 25, width: 400, height: 400))
    }

    @Test func tilesNeverOverlapAndCoverTheArea() {
        let odd = CGRect(x: 0, y: 0, width: 1001, height: 599)
        let layout = tree(.horizontal, [leaf(1), leaf(2), box(.vertical, [leaf(3), leaf(4), leaf(5)]), leaf(6)])
        let result = Array(frames(layout, area: odd).values)
        for (index, first) in result.enumerated() {
            for second in result.dropFirst(index + 1) {
                #expect(first.intersection(second).width <= 0 || first.intersection(second).height <= 0)
            }
        }
        let area = result.reduce(0) { $0 + $1.width * $1.height }
        #expect(area == odd.width * odd.height)
    }

    @Test func aTinyAreaNeverGivesNegativeSizes() {
        let result = frames(
            tree(.horizontal, [leaf(1), leaf(2), leaf(3)]), gaps: TilingGaps(inner: 50, outer: 50),
            area: CGRect(x: 0, y: 0, width: 60, height: 40))
        for frame in result.values { #expect(frame.width >= 0 && frame.height >= 0) }
        #expect(result.count == 3)
    }

    @Test func manyWindowsWithABigGapStayInsideTheAreaWithPositiveSizes() {
        let many = tree(.horizontal, (1...40).map { leaf(UInt32($0)) })
        let result = Array(frames(many, gaps: TilingGaps(inner: 16, outer: 0)).values)
        #expect(result.count == 40)
        for frame in result {
            #expect(frame.width >= 1 && frame.height == 600)
            #expect(frame.minX >= 0 && frame.maxX <= screen.maxX)
        }
        let ordered = result.sorted { $0.minX < $1.minX }
        for (first, second) in zip(ordered, ordered.dropFirst()) { #expect(first.maxX <= second.minX) }
    }

    @Test func anEmptyTreeHasNoFrames() {
        #expect(frames(TilingTree()).isEmpty)
    }

    // MARK: Insert

    @Test func theFirstWindowsAppendToTheRoot() {
        var layout = TilingTree(orientation: .vertical)
        layout.insert(win(1))
        layout.insert(win(2))
        #expect(numbers(layout) == [1, 2])
        #expect(layout.rootOrientation == .vertical)
    }

    @Test func aNewWindowGoesAfterTheFocusedOneInItsContainer() {
        var layout = tree(.horizontal, [leaf(1), box(.vertical, [leaf(2), leaf(3)]), leaf(4)])
        layout.insert(win(5), after: win(2))
        #expect(numbers(layout) == [1, 2, 5, 3, 4])
        // It joined the vertical container of window 2.
        #expect(layout.path(to: win(5)) == [1, 1])
    }

    @Test func aNewWindowTakesTheAverageWeight() {
        var layout = tree(.horizontal, [leaf(1, 3), leaf(2, 1)])
        layout.insert(win(3), after: win(1))
        let weights = layout.root.children.map(\.weight)
        #expect(weights == [3, 2, 1])
    }

    @Test func anUnknownAnchorAppends() {
        var layout = tree(.horizontal, [leaf(1), leaf(2)])
        layout.insert(win(3), after: win(99))
        #expect(numbers(layout) == [1, 2, 3])
    }

    @Test func insertingAWindowTwiceChangesNothing() {
        var layout = tree(.horizontal, [leaf(1), leaf(2)])
        let before = layout
        layout.insert(win(1))
        layout.insert(win(2), after: win(1))
        #expect(layout == before)
    }

    // MARK: Remove

    @Test func removingAWindowDropsItsTile() {
        var layout = tree(.horizontal, [leaf(1), leaf(2), leaf(3)])
        let first = layout.remove(win(2))
        #expect(first)
        #expect(numbers(layout) == [1, 3])
        let second = layout.remove(win(2))
        #expect(!second)
    }

    @Test func aContainerWithOneChildLeftIsReplacedByIt() {
        var layout = tree(.horizontal, [leaf(1), box(.vertical, 2, [leaf(2), leaf(3)])])
        layout.remove(win(3))
        #expect(layout.root.children == [leaf(1), leaf(2, 2)])
    }

    @Test func theLastWindowOfANestedContainerRemovesTheContainer() {
        var layout = tree(.horizontal, [leaf(1), box(.vertical, [leaf(2), leaf(3)])])
        layout.remove(win(2))
        layout.remove(win(3))
        #expect(layout.root.children == [leaf(1)])
    }

    @Test func removingEveryWindowLeavesAnEmptyRootThatKeepsItsOrientation() {
        var layout = tree(.vertical, [leaf(1), leaf(2)])
        layout.remove(win(1))
        layout.remove(win(2))
        #expect(layout.isEmpty)
        #expect(layout.rootOrientation == .vertical)
    }

    // MARK: Canonical form

    @Test func aNestedContainerOfTheSameOrientationIsMerged() {
        let layout = tree(.horizontal, [leaf(1, 2), box(.horizontal, 2, [leaf(2, 1), leaf(3, 3)])])
        #expect(layout.root.children.count == 3)
        #expect(layout.root.children.map(\.weight) == [2, 0.5, 1.5])
        #expect(numbers(layout) == [1, 2, 3])
    }

    @Test func aRootWithOnlyAContainerAdoptsIt() {
        let layout = tree(.horizontal, [box(.vertical, [leaf(1), leaf(2)])])
        #expect(layout.rootOrientation == .vertical)
        #expect(layout.root.children.count == 2)
    }

    @Test func badWeightsBecomeOne() {
        let layout = tree(.horizontal, [leaf(1, 0), leaf(2, -3), leaf(3, .nan), leaf(4, .infinity)])
        #expect(layout.root.children.map(\.weight) == [1, 1, 1, 1])
    }

    @Test func theStrategyKeepsItsStateUnderTheTilingKind() {
        let strategy = TilingStrategy()
        #expect(strategy.kind == .tiling)
        var config = EngineConfig()
        config.layout = LayoutConfig(
            defaultKind: .tiling, innerGap: 0, outerGap: 0, rootOrientation: .vertical, overrides: [:])
        func input(_ windows: [WindowID], state: AnyLayoutState?) -> LayoutInput {
            LayoutInput(
                workspace: WorkspaceID(1)!, windows: windows, apps: [:], state: state, config: nil,
                resolved: config.layout.resolved(for: WorkspaceID(1)!), focused: win(1), previousFocus: nil,
                display: DisplayInfo(id: 1, uuid: "A", frame: screen), displayKey: "A", hints: [:])
        }
        let first = strategy.arrange(input([win(1), win(2)], state: nil))
        #expect(first.state?.as(TilingTree.self)?.windows.map(\.number) == [1, 2])
        #expect(first.frames[win(2)] == CGRect(x: 0, y: 300, width: 1000, height: 300))
        // A window that left goes, and what the strategy stores round-trips through its JSON.
        let second = strategy.arrange(input([win(2)], state: first.state))
        #expect(second.state?.as(TilingTree.self)?.windows.map(\.number) == [2])
        let json = second.state.flatMap(strategy.encode)
        #expect(json.flatMap(strategy.decode) == second.state)
        #expect(strategy.removing(win(2), from: second.state ?? first.state!).isEmpty)
    }
}
