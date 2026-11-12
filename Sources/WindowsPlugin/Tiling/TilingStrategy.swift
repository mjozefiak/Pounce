import CoreGraphics
import Foundation
import LintelKit

extension TilingTree: LayoutStateValue {}

/// Auto-tile: an i3/AeroSpace-style tree of split containers per workspace (state kind `tiling`).
struct TilingStrategy: LayoutStrategy {
    var kind: LayoutKind { .tiling }
    var displayName: String {
        String(localized: "Auto-tile", comment: "Window Management layout kind: windows tile the screen")
    }

    // MARK: Options

    static let innerGapID = "innerGap"
    static let outerGapID = "outerGap"
    static let rootOrientationID = "rootOrientation"
    static let resizeStepID = "resizeStep"
    static let defaultGap = 10
    static let maximumGap = 64

    /// The gaps and the first split: the global gaps are `plugins.windows.gap.inner` and `gap.outer`, the first
    /// split has no global setting (side by side).
    var options: [LayoutOption] {
        [
            LayoutOption(
                id: Self.innerGapID,
                title: String(localized: "Space between windows", comment: "Window Management setting: the inner gap"),
                domain: .points(0...Self.maximumGap), defaultValue: .int(Self.defaultGap),
                settingKey: WindowsSettings.Key.innerGap),
            LayoutOption(
                id: Self.outerGapID,
                title: String(localized: "Space around windows", comment: "Window Management setting: the outer gap"),
                domain: .points(0...Self.maximumGap), defaultValue: .int(Self.defaultGap),
                settingKey: WindowsSettings.Key.outerGap),
            LayoutOption(
                id: Self.rootOrientationID,
                title: String(
                    localized: "First split", comment: "Window Management: the root orientation of one workspace"),
                domain: .choices(
                    TilingOrientation.allCases.map { LayoutOption.Choice(id: $0.rawValue, title: $0.displayName) }),
                defaultValue: .string(TilingOrientation.horizontal.rawValue), settingKey: nil),
            LayoutOption(
                id: Self.resizeStepID,
                title: String(
                    localized: "Resize step", comment: "Window Management setting: points one grow or shrink moves"),
                domain: .points(WindowsSettings.resizeStepRange), defaultValue: .int(WindowsSettings.defaultResizeStep),
                settingKey: WindowsSettings.Key.resizeStep),
        ]
    }

    func summaryParts(_ resolved: ResolvedLayout) -> [String] {
        let gaps = resolved.tilingGaps
        let inner = Int(gaps.inner)
        let outer = Int(gaps.outer)
        return [
            String(localized: "Gaps \(inner) / \(outer)", comment: "Window Management summary: gaps"),
            resolved.tilingOrientation.displayName,
        ]
    }

    // MARK: Commands

    /// Join, resize, split direction and balance (the focus and move verbs are shared by every kind, see
    /// `LayoutCommand.focus`). Resize is a family with ⌥- and ⌥= by default.
    var commands: [LayoutCommandSpec] {
        var specs: [LayoutCommandSpec] = [
            LayoutCommandSpec(
                id: WindowsCommandID.grow,
                title: LocalizedStringResource("Grow Window", comment: "Command: makes the focused tile larger"),
                symbolName: "arrow.up.left.and.arrow.down.right", family: .resize, key: "=",
                command: .resizeSteps(1)),
            LayoutCommandSpec(
                id: WindowsCommandID.shrink,
                title: LocalizedStringResource("Shrink Window", comment: "Command: makes the focused tile smaller"),
                symbolName: "arrow.down.right.and.arrow.up.left", family: .resize, key: "-",
                command: .resizeSteps(-1)),
        ]
        for direction in LayoutDirection.allCases {
            specs.append(
                LayoutCommandSpec(
                    id: WindowsCommandID.join(direction), title: Self.joinTitle(direction),
                    symbolName: "rectangle.split.2x1", command: .join(direction)))
        }
        specs.append(
            LayoutCommandSpec(
                id: WindowsCommandID.toggleOrientation,
                title: LocalizedStringResource(
                    "Toggle Split Direction", comment: "Command: flips the container of the focused window"),
                symbolName: "rectangle.split.2x1", command: .toggleOrientation))
        specs.append(
            LayoutCommandSpec(
                id: WindowsCommandID.balance,
                title: LocalizedStringResource("Balance Windows", comment: "Command: gives every tile the same size"),
                symbolName: "equal.square", command: .balance))
        return specs
    }

    private static func joinTitle(_ direction: LayoutDirection) -> LocalizedStringResource {
        switch direction {
        case .left:
            LocalizedStringResource(
                "Join with Left Window", comment: "Command: groups the focused window with its neighbour")
        case .right:
            LocalizedStringResource(
                "Join with Right Window", comment: "Command: groups the focused window with its neighbour")
        case .up:
            LocalizedStringResource(
                "Join with Window Above", comment: "Command: groups the focused window with its neighbour")
        case .down:
            LocalizedStringResource(
                "Join with Window Below", comment: "Command: groups the focused window with its neighbour")
        }
    }

    func arrange(_ input: LayoutInput) -> LayoutArrangement {
        let layout = input.resolved
        let orientation = layout.tilingOrientation
        let wanted = Set(input.windows)
        var tree = input.state?.as(TilingTree.self) ?? TilingTree(orientation: orientation)
        // Windows that are gone, floating or moved away leave the tree.
        for id in tree.windows where !wanted.contains(id) { tree.remove(id) }
        if tree.windows.count <= 1 { tree.root.orientation = orientation }
        // New windows enter after the focused window (or the one focused before it), several in join order.
        var anchor: WindowID?
        for id in input.windows where !tree.contains(id) {
            if anchor == nil {
                anchor = [input.focused, input.previousFocus].lazy.compactMap { $0 }
                    .first { $0 != id && tree.contains($0) }
            }
            tree.insert(id, after: anchor)
            anchor = id
        }
        return LayoutArrangement(
            state: AnyLayoutState(tree), frames: TilingLayout.frames(tree, area: input.area, gaps: layout.tilingGaps),
            hints: input.hints)
    }

    func perform(_ command: LayoutCommand, on window: WindowID, _ input: LayoutInput) -> LayoutEdit? {
        guard let tree = input.state?.as(TilingTree.self) else { return nil }
        var next = tree
        switch command.id {
        case LayoutCommand.focusID:
            guard let direction = command.direction,
                let target = TilingNavigation.neighbour(of: window, direction, in: tree)
            else { return nil }
            return LayoutEdit(state: AnyLayoutState(tree), focus: target, hints: input.hints)
        case LayoutCommand.moveID:
            guard let direction = command.direction, let moved = TilingNavigation.move(window, direction, in: tree)
            else { return nil }
            next = moved
        case LayoutCommand.resizeID:
            guard let delta = command.payload(as: Double.self), next.resize(window, by: delta) else { return nil }
        case LayoutCommand.resizeStepsID:
            guard let steps = command.payload(as: Double.self),
                let share = Self.share(ofSteps: steps, window: window, tree: tree, input: input),
                next.resize(window, by: share)
            else { return nil }
        case LayoutCommand.joinID:
            guard let direction = command.direction, next.join(window, direction) else { return nil }
        case LayoutCommand.toggleOrientationID:
            guard next.toggleOrientation(of: window) else { return nil }
        case LayoutCommand.balanceID:
            next.balance()
            if next == tree { return nil }
        default:
            return nil
        }
        return LayoutEdit(state: AnyLayoutState(next), focus: nil, hints: input.hints)
    }

    /// The share of the container that `steps` resize steps (points) are along the axis of the container `resize`
    /// will change: the window's own container when it has siblings, else the nearest one around it that does.
    private static func share(ofSteps steps: Double, window: WindowID, tree: TilingTree, input: LayoutInput) -> Double?
    {
        guard let path = tree.path(to: window) else { return nil }
        let points = Double(input.resolved.int(resizeStepID) ?? WindowsSettings.defaultResizeStep)
        let frames = TilingLayout.frames(tree, area: input.area, gaps: input.resolved.tilingGaps)
        for depth in stride(from: path.count - 1, through: 0, by: -1) {
            guard let container = tree.root.container(at: path[0..<depth]), container.children.count > 1 else {
                continue
            }
            let rects = container.windows.compactMap { frames[$0] }
            guard let first = rects.first else { return nil }
            let union = rects.dropFirst().reduce(first) { $0.union($1) }
            let length = container.orientation == .horizontal ? union.width : union.height
            guard length > 0 else { return nil }
            return steps * points / Double(length)
        }
        return nil
    }

    func removing(_ window: WindowID, from state: AnyLayoutState) -> AnyLayoutState {
        guard var tree = state.as(TilingTree.self) else { return state }
        tree.remove(window)
        return AnyLayoutState(tree)
    }

    func encode(_ state: AnyLayoutState) -> JSONValue? {
        state.as(TilingTree.self).flatMap { JSONValue(encoding: TilingRecord($0)) }
    }

    func decode(_ json: JSONValue) -> AnyLayoutState? {
        guard let tree = json.decoded(as: TilingRecord.self)?.tree, !tree.isEmpty else { return nil }
        return AnyLayoutState(tree)
    }
}

// The commands only Auto-tile understands.
extension LayoutCommand {
    static let resizeID = "tiling.resize"
    /// Grows (positive) or shrinks (negative) by that many resize steps (`plugins.windows.resize.step` points).
    static let resizeStepsID = "tiling.resizeSteps"
    static let joinID = "tiling.join"
    static let toggleOrientationID = "tiling.toggleOrientation"
    static let balanceID = "tiling.balance"

    /// Grows (positive) or shrinks (negative) the window by that share of its container.
    static func resize(_ delta: Double) -> LayoutCommand { LayoutCommand(resizeID, encoding: delta) }
    static func resizeSteps(_ steps: Double) -> LayoutCommand { LayoutCommand(resizeStepsID, encoding: steps) }
    /// Puts the window and its neighbour in that direction into a new container.
    static func join(_ direction: LayoutDirection) -> LayoutCommand { LayoutCommand(joinID, encoding: direction) }
    static let toggleOrientation = LayoutCommand(toggleOrientationID)
    static let balance = LayoutCommand(balanceID)
}

extension EngineCommand {
    static func resize(_ delta: Double) -> EngineCommand { .layout(.resize(delta)) }
    static func resizeSteps(_ steps: Double) -> EngineCommand { .layout(.resizeSteps(steps)) }
    static func join(_ direction: LayoutDirection) -> EngineCommand { .layout(.join(direction)) }
    static let toggleOrientation = EngineCommand.layout(.toggleOrientation)
    static let balance = EngineCommand.layout(.balance)
}

extension TilingOrientation {
    /// How the first split of a workspace is named in the pane and the summary.
    var displayName: String {
        switch self {
        case .horizontal:
            String(
                localized: "Side by side", comment: "Window Management: the first split of a workspace is horizontal")
        case .vertical:
            String(localized: "Stacked", comment: "Window Management: the first split of a workspace is vertical")
        }
    }
}

extension ResolvedLayout {
    /// The gaps of an Auto-tile workspace (the option values, in points).
    var tilingGaps: TilingGaps {
        TilingGaps(
            inner: CGFloat(int(TilingStrategy.innerGapID) ?? TilingStrategy.defaultGap),
            outer: CGFloat(int(TilingStrategy.outerGapID) ?? TilingStrategy.defaultGap))
    }

    /// The first split of an Auto-tile workspace.
    var tilingOrientation: TilingOrientation {
        string(TilingStrategy.rootOrientationID).flatMap(TilingOrientation.init(rawValue:)) ?? .horizontal
    }
}
