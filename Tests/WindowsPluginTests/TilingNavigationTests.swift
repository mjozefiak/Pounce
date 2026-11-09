import CoreGraphics
import LintelKit
import Testing

@testable import WindowsPlugin

/// Directional focus and move in a tree (step 2.2), table driven.
@Suite struct TilingNavigationTests {
    /// 1 | (2 over 3) | 4
    private var sample: TilingTree { tree(.horizontal, [leaf(1), box(.vertical, [leaf(2), leaf(3)]), leaf(4)]) }

    struct FocusCase: CustomTestStringConvertible, Sendable {
        var from: UInt32
        var direction: TilingDirection
        var expected: UInt32?
        var testDescription: String { "\(from) \(direction) -> \(expected.map(String.init) ?? "none")" }
    }

    static let focusCases: [FocusCase] = [
        FocusCase(from: 1, direction: .right, expected: 2),
        FocusCase(from: 2, direction: .right, expected: 4),
        FocusCase(from: 3, direction: .right, expected: 4),
        FocusCase(from: 4, direction: .left, expected: 2),
        FocusCase(from: 3, direction: .left, expected: 1),
        FocusCase(from: 2, direction: .left, expected: 1),
        FocusCase(from: 2, direction: .down, expected: 3),
        FocusCase(from: 3, direction: .up, expected: 2),
        FocusCase(from: 2, direction: .up, expected: nil),
        FocusCase(from: 3, direction: .down, expected: nil),
        FocusCase(from: 1, direction: .left, expected: nil),
        FocusCase(from: 4, direction: .right, expected: nil),
        FocusCase(from: 1, direction: .up, expected: nil),
        FocusCase(from: 4, direction: .down, expected: nil),
    ]

    @Test(arguments: focusCases)
    func focusFollowsTheTiles(_ item: FocusCase) {
        let result = TilingNavigation.neighbour(of: win(item.from), item.direction, in: sample)
        #expect(result?.number == item.expected)
    }

    @Test func focusPicksTheTileAcrossFromTheMiddle() {
        // 1 beside a column of three: the middle one faces the middle of 1.
        let layout = tree(.horizontal, [leaf(1), box(.vertical, [leaf(2), leaf(3), leaf(4)])])
        #expect(TilingNavigation.neighbour(of: win(1), .right, in: layout)?.number == 3)
        #expect(TilingNavigation.neighbour(of: win(2), .left, in: layout)?.number == 1)
    }

    @Test func focusOfAnUnknownWindowIsNil() {
        #expect(TilingNavigation.neighbour(of: win(99), .right, in: sample) == nil)
    }

    struct MoveCase: CustomTestStringConvertible, Sendable {
        var window: UInt32
        var direction: TilingDirection
        /// The expected tree as a description, `nil` when nothing changes.
        var expected: String?
        var testDescription: String { "\(window) \(direction)" }
    }

    /// `[1 (2 3) 4]` is a horizontal root, `(...)` a vertical container, `{...}` a horizontal one.
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

    static let moveCases: [MoveCase] = [
        // Swap with a window neighbour.
        MoveCase(window: 2, direction: .down, expected: "[1 (3 2) 4]"),
        MoveCase(window: 3, direction: .up, expected: "[1 (3 2) 4]"),
        // Into a neighbouring container, at its near edge.
        MoveCase(window: 1, direction: .right, expected: "[(1 2 3) 4]"),
        MoveCase(window: 4, direction: .left, expected: "[1 (2 3 4)]"),
        // Out of a nested container, beside it.
        MoveCase(window: 2, direction: .left, expected: "[1 2 3 4]"),
        MoveCase(window: 3, direction: .right, expected: "[1 2 3 4]"),
        // At the edge of everything.
        MoveCase(window: 1, direction: .left, expected: nil),
        MoveCase(window: 4, direction: .right, expected: nil),
        MoveCase(window: 1, direction: .up, expected: nil),
        MoveCase(window: 3, direction: .down, expected: nil),
        MoveCase(window: 2, direction: .up, expected: nil),
    ]

    @Test(arguments: moveCases)
    func moveRearrangesTheTree(_ item: MoveCase) {
        let result = TilingNavigation.move(win(item.window), item.direction, in: sample)
        #expect(result.map { describe($0.root) } == item.expected)
    }

    @Test func movingAcrossTwoWindowsSwapsThem() {
        let layout = tree(.horizontal, [leaf(1), leaf(2)])
        let result = TilingNavigation.move(win(1), .right, in: layout)
        #expect(result.map(numbers) == [2, 1])
    }

    @Test func swapKeepsTheWeightsOfThePlaces() {
        let layout = tree(.horizontal, [leaf(1, 3), leaf(2, 1)])
        let result = TilingNavigation.move(win(1), .right, in: layout)
        #expect(result?.root.children.map(\.weight) == [3, 1])
        #expect(result.map(numbers) == [2, 1])
    }

    @Test func movingOutFromTheDeepEndOfAnOuterBranch() {
        // [1 (2 {3 4})]: 3 left has no neighbour in {3 4}; the vertical level does not split sideways; the
        // root does, so 3 lands before the column.
        let layout = tree(.horizontal, [leaf(1), box(.vertical, [leaf(2), box(.horizontal, [leaf(3), leaf(4)])])])
        let result = TilingNavigation.move(win(3), .left, in: layout)
        #expect(result.map { describe($0.root) } == "[1 3 (2 4)]")
    }

    @Test func movingAnUnknownWindowIsNil() {
        #expect(TilingNavigation.move(win(99), .left, in: sample) == nil)
    }

    @Test func aMoveNeverLosesOrDuplicatesAWindow() {
        for window in [1, 2, 3, 4] as [UInt32] {
            for direction in TilingDirection.allCases {
                guard let result = TilingNavigation.move(win(window), direction, in: sample) else { continue }
                #expect(Set(numbers(result)) == [1, 2, 3, 4])
                #expect(numbers(result).count == 4)
            }
        }
    }
}
