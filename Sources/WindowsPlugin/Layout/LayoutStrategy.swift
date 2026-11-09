import CoreGraphics
import Foundation
import LintelKit

// The engine's abstraction over how a workspace is arranged (spec: Architecture, "Strategy pattern for
// layouts"). The reducer knows no kind: it asks the strategy of the workspace's resolved kind to bring its state
// up to date with the windows and to say where each goes, and hands it the commands that edit that state. Every
// kind keeps its own state as an opaque value (`AnyLayoutState`) under the kind's name, in memory and in
// `state.json`, so a later strategy is one new type and one line in `LayoutRegistry`.

/// The state of one kind for one workspace.
protocol LayoutStateValue: Sendable {
    var isEmpty: Bool { get }
    func isEqual(to other: any LayoutStateValue) -> Bool
}

extension LayoutStateValue where Self: Equatable {
    func isEqual(to other: any LayoutStateValue) -> Bool { (other as? Self) == self }
}

/// A strategy's state with its type erased.
struct AnyLayoutState: Equatable, Sendable {
    let value: any LayoutStateValue

    init(_ value: some LayoutStateValue) { self.value = value }

    func `as`<State: LayoutStateValue>(_ type: State.Type) -> State? { value as? State }

    var isEmpty: Bool { value.isEmpty }

    static func == (lhs: AnyLayoutState, rhs: AnyLayoutState) -> Bool { lhs.value.isEqual(to: rhs.value) }
}

/// What `state.json` holds for a kind this build has no strategy for: kept as it is and written back unchanged.
struct OpaqueLayoutState: LayoutStateValue, Equatable {
    var json: JSONValue
    var isEmpty: Bool { false }
}

/// What a strategy needs to arrange one workspace on the display that shows it.
struct LayoutInput: Sendable {
    var workspace: WorkspaceID
    /// The windows to arrange, in join order: tracked, not floating, not left alone.
    var windows: [WindowID]
    /// The bundle id of each window in `windows`, for placement memory; never stored or logged.
    var apps: [WindowID: String]
    var state: AnyLayoutState?
    var focused: WindowID?
    var previousFocus: WindowID?
    var display: DisplayInfo
    var displayKey: String
    var config: EngineConfig
    /// Placement memory shared by the strategies, keyed by app (memory only).
    var hints: [String: Int]

    var resolved: ResolvedLayout { config.layout.resolved(for: workspace) }
    var area: CGRect { display.visibleFrame }
}

struct LayoutArrangement: Sendable {
    var state: AnyLayoutState?
    var frames: [WindowID: CGRect]
    var hints: [String: Int]
}

/// A command that edits a strategy's state; a strategy that does not know it answers `nil`.
enum LayoutOperation: Equatable, Sendable {
    case focus(TilingDirection)
    case move(TilingDirection)
    case resize(Double)
    case join(TilingDirection)
    case toggleOrientation
    case balance
    /// Moves the window to a slot of the layout by its number (a zone, 1 to 9).
    case slot(Int)
    /// A drag released over a slot (by its id in the layout) of the layout shown on a display.
    case snap(slotID: Int, displayKey: String)
}

struct LayoutEdit: Sendable {
    var state: AnyLayoutState
    /// The window the focus moves to, for a command that moves the focus.
    var focus: WindowID?
    var hints: [String: Int]
}

protocol LayoutStrategy: Sendable {
    var kind: LayoutKind { get }
    /// Brings the state up to date with `input.windows` (windows that left go, new ones enter by the kind's
    /// rule) and returns where every window goes. Pure.
    func arrange(_ input: LayoutInput) -> LayoutArrangement
    /// The edit a command makes to `input.state` (already up to date) for `window`, or `nil`.
    func perform(_ operation: LayoutOperation, on window: WindowID, _ input: LayoutInput) -> LayoutEdit?
    /// The state without a window that is gone.
    func removing(_ window: WindowID, from state: AnyLayoutState) -> AnyLayoutState
    /// The slots the snap overlay offers for the workspace, empty when the kind has none.
    func snapTargets(_ input: LayoutInput) -> [DragDisplay]
    /// The JSON stored under the kind's name; `nil` for an empty state.
    func encode(_ state: AnyLayoutState) -> JSONValue?
    /// The state a stored JSON describes; `nil` when it does not decode (it is dropped, not a corrupt file).
    func decode(_ json: JSONValue) -> AnyLayoutState?
}

extension LayoutStrategy {
    func perform(_ operation: LayoutOperation, on window: WindowID, _ input: LayoutInput) -> LayoutEdit? { nil }
    func removing(_ window: WindowID, from state: AnyLayoutState) -> AnyLayoutState { state }
    func snapTargets(_ input: LayoutInput) -> [DragDisplay] { [] }
    func encode(_ state: AnyLayoutState) -> JSONValue? { nil }
    func decode(_ json: JSONValue) -> AnyLayoutState? { nil }
}

/// Free: nothing is arranged, nothing is stored.
struct FreeStrategy: LayoutStrategy {
    var kind: LayoutKind { .free }

    func arrange(_ input: LayoutInput) -> LayoutArrangement {
        LayoutArrangement(state: input.state, frames: [:], hints: input.hints)
    }
}

/// The strategies of this build, by kind. The reducer and the engine take it as an argument, so a test can pass a
/// registry of its own.
struct LayoutRegistry: Sendable {
    static let standard = LayoutRegistry([TilingStrategy(), ZonesStrategy(), FreeStrategy()])

    private let strategies: [LayoutKind: any LayoutStrategy]

    init(_ strategies: [any LayoutStrategy]) {
        self.strategies = Dictionary(strategies.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
    }

    subscript(kind: LayoutKind) -> (any LayoutStrategy)? { strategies[kind] }

    /// The state stored under a kind's name: decoded by its strategy, kept opaque for a kind this build does not
    /// know, dropped (`nil`) when a known kind does not decode.
    func decode(kindName: String, json: JSONValue) -> AnyLayoutState? {
        guard let kind = LayoutKind(rawValue: kindName) else { return AnyLayoutState(OpaqueLayoutState(json: json)) }
        return strategies[kind]?.decode(json)
    }

    func decode(_ stored: [WorkspaceID: [String: JSONValue]]) -> [WorkspaceID: [String: AnyLayoutState]] {
        var result: [WorkspaceID: [String: AnyLayoutState]] = [:]
        for (workspace, kinds) in stored {
            for (name, json) in kinds {
                if let state = decode(kindName: name, json: json) { result[workspace, default: [:]][name] = state }
            }
        }
        return result
    }

    func encode(_ states: [WorkspaceID: [String: AnyLayoutState]]) -> [WorkspaceID: [String: JSONValue]] {
        var result: [WorkspaceID: [String: JSONValue]] = [:]
        for (workspace, kinds) in states {
            for (name, state) in kinds {
                let json: JSONValue?
                if let opaque = state.as(OpaqueLayoutState.self) {
                    json = opaque.json
                } else if let kind = LayoutKind(rawValue: name), !state.isEmpty {
                    json = strategies[kind]?.encode(state)
                } else {
                    json = nil
                }
                if let json { result[workspace, default: [:]][name] = json }
            }
        }
        return result
    }
}
