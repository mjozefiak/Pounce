import CoreGraphics
import Foundation
import LintelKit

// The engine's abstraction over how a workspace is arranged (spec: Architecture, "Strategy pattern for layouts").
// The reducer, the state, the store and the engine know no kind. A strategy owns its kind's state, its
// configuration and the commands it understands, all opaque to the rest; a new strategy is one new type and one
// line in `LayoutRegistry`.

// MARK: State

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

// MARK: Configuration

/// A strategy's configuration (for Zones: the layout library and the assignments).
protocol LayoutConfigValue: Sendable {
    func isEqual(to other: any LayoutConfigValue) -> Bool
}

extension LayoutConfigValue where Self: Equatable {
    func isEqual(to other: any LayoutConfigValue) -> Bool { (other as? Self) == self }
}

struct AnyLayoutConfig: Equatable, Sendable {
    let value: any LayoutConfigValue

    init(_ value: some LayoutConfigValue) { self.value = value }

    func `as`<Config: LayoutConfigValue>(_ type: Config.Type) -> Config? { value as? Config }

    static func == (lhs: AnyLayoutConfig, rhs: AnyLayoutConfig) -> Bool { lhs.value.isEqual(to: rhs.value) }
}

/// What a strategy may read to build its configuration: the plugin's settings and the stored data a layout kind
/// can need (the assignments and the layout library live in their own files).
struct LayoutEnvironment: Sendable {
    var settings: WindowsSettings
    var assignments = AssignmentTable()
    var library = LayoutLibrary.stock
}

// MARK: Commands

/// A command a strategy understands: an id and a payload, both opaque to the engine. The ids and payloads of a kind
/// are defined next to its strategy; a strategy that does not know an id answers `nil`.
struct LayoutCommand: Equatable, Sendable {
    var id: String
    var payload: JSONValue

    init(_ id: String, payload: JSONValue = .null) {
        self.id = id
        self.payload = payload
    }

    init<Payload: Encodable>(_ id: String, encoding payload: Payload) {
        self.id = id
        self.payload = JSONValue(encoding: payload) ?? .null
    }

    func payload<Payload: Decodable>(as type: Payload.Type) -> Payload? { payload.decoded(as: type) }
}

/// What a strategy needs to arrange one workspace on the display that shows it.
struct LayoutInput: Sendable {
    var workspace: WorkspaceID
    /// The windows to arrange, in join order: tracked, not floating, not left alone.
    var windows: [WindowID]
    /// The bundle id of each window in `windows`, for placement memory; never stored or logged.
    var apps: [WindowID: String]
    var state: AnyLayoutState?
    /// This kind's own configuration, if the plugin has one for it.
    var config: AnyLayoutConfig?
    /// The kind and the option values the workspace resolved to (`LayoutStrategy.options`).
    var resolved: ResolvedLayout
    var focused: WindowID?
    var previousFocus: WindowID?
    var display: DisplayInfo
    var displayKey: String
    /// Placement memory shared by the strategies, keyed by app (memory only).
    var hints: [String: Int]

    var area: CGRect { display.visibleFrame }
}

struct LayoutArrangement: Sendable {
    var state: AnyLayoutState?
    var frames: [WindowID: CGRect]
    var hints: [String: Int]
}

struct LayoutEdit: Sendable {
    var state: AnyLayoutState
    /// The window the focus moves to, for a command that moves the focus.
    var focus: WindowID?
    var hints: [String: Int]
}

// MARK: Strategy

protocol LayoutStrategy: Sendable {
    var kind: LayoutKind { get }
    /// The kind's name in the pane and the Layouts window.
    var displayName: String { get }
    /// Whether the Layouts window assigns layouts from the library to this kind's workspaces (the cells of its
    /// matrix are active for them).
    var usesLayoutLibrary: Bool { get }
    /// The settings of this kind: a global default (when an option names a setting) and a per-workspace override,
    /// drawn by the pane and delivered to `arrange` in `LayoutInput.resolved`. Option ids are unique across the
    /// registry (a strategy that repeats an id of an earlier one, or of the plugin's own keys, is left out).
    var options: [LayoutOption] { get }
    /// The commands of this kind (Auto-tile: join, resize, balance; Zones: move to zone N), added to the plugin's
    /// command catalogue next to the shared ones. Ids are `windows.<...>` and never change once shipped.
    var commands: [LayoutCommandSpec] { get }
    /// What the per-workspace summary adds for this kind after its name (Auto-tile: gaps and orientation).
    func summaryParts(_ resolved: ResolvedLayout) -> [String]
    /// The id of the library layout the workspace shows on a display, `nil` for a kind that does not use the
    /// layout library (`usesLayoutLibrary`). *Next zone layout* steps from it.
    func libraryLayoutID(
        _ environment: LayoutEnvironment, workspace: WorkspaceID, displayKey: String, orientation: DisplayOrientation
    ) -> String?
    /// This kind's configuration from the settings and stored data, `nil` when it has none.
    func makeConfig(_ environment: LayoutEnvironment) -> AnyLayoutConfig?
    /// Brings the state up to date with `input.windows` (windows that left go, new ones enter by the kind's
    /// rule) and returns where every window goes. Pure.
    func arrange(_ input: LayoutInput) -> LayoutArrangement
    /// The edit a command makes to `input.state` (already up to date) for `window`, or `nil` when the command is
    /// not one of this kind's or changes nothing.
    func perform(_ command: LayoutCommand, on window: WindowID, _ input: LayoutInput) -> LayoutEdit?
    /// The state without a window that is gone.
    func removing(_ window: WindowID, from state: AnyLayoutState) -> AnyLayoutState
    /// Whether the kind has snap targets at all (so a manual window move may start a drag): cheap, no input.
    var offersSnapTargets: Bool { get }
    /// The slots the snap overlay offers for the workspace, empty when the kind has none.
    func snapTargets(_ input: LayoutInput) -> [DragDisplay]
    /// The JSON stored under the kind's name; `nil` for an empty state.
    func encode(_ state: AnyLayoutState) -> JSONValue?
    /// The state a stored JSON describes; `nil` when it does not decode (it is dropped, not a corrupt file).
    func decode(_ json: JSONValue) -> AnyLayoutState?
}

extension LayoutStrategy {
    var displayName: String { kind.rawValue }
    var usesLayoutLibrary: Bool { false }
    var options: [LayoutOption] { [] }
    var commands: [LayoutCommandSpec] { [] }
    func summaryParts(_ resolved: ResolvedLayout) -> [String] { [] }
    func libraryLayoutID(
        _ environment: LayoutEnvironment, workspace: WorkspaceID, displayKey: String, orientation: DisplayOrientation
    ) -> String? { nil }
    func makeConfig(_ environment: LayoutEnvironment) -> AnyLayoutConfig? { nil }
    func perform(_ command: LayoutCommand, on window: WindowID, _ input: LayoutInput) -> LayoutEdit? { nil }
    func removing(_ window: WindowID, from state: AnyLayoutState) -> AnyLayoutState { state }
    var offersSnapTargets: Bool { false }
    func snapTargets(_ input: LayoutInput) -> [DragDisplay] { [] }
    func encode(_ state: AnyLayoutState) -> JSONValue? { nil }
    func decode(_ json: JSONValue) -> AnyLayoutState? { nil }
}

/// Free: nothing is arranged, nothing is stored.
struct FreeStrategy: LayoutStrategy {
    var kind: LayoutKind { .free }
    var displayName: String {
        String(localized: "Free", comment: "Window Management layout kind: windows are left where they are")
    }

    func arrange(_ input: LayoutInput) -> LayoutArrangement {
        LayoutArrangement(state: input.state, frames: [:], hints: input.hints)
    }
}

// MARK: Registry

/// The strategies of this build, by kind. The reducer and the engine take it as an argument, so a test can pass a
/// registry of its own.
struct LayoutRegistry: Sendable {
    static let standard = LayoutRegistry([TilingStrategy(), ZonesStrategy(), FreeStrategy()])

    private let strategies: [LayoutKind: any LayoutStrategy]
    /// The kinds in registration order: what the pane offers and *Toggle layout* cycles through.
    let kinds: [LayoutKind]

    /// Kind names that cannot be used: they are keys of a workspace record in `state.json` next to the per-kind
    /// state.
    static let reservedKindNames: Set<String> = ["order"]

    /// A strategy whose kind is reserved (or repeats an earlier one), or one of whose option ids repeats an earlier
    /// id (or is `kind`, the key of an override record), is left out: it could not be stored safely.
    init(_ strategies: [any LayoutStrategy]) {
        var seen = Set<LayoutKind>()
        var optionIDs: Set<String> = [WorkspaceOverrides.kindKey]
        let usable = strategies.filter { strategy in
            guard !Self.reservedKindNames.contains(strategy.kind.rawValue), !seen.contains(strategy.kind) else {
                return false
            }
            let ids = strategy.options.map(\.id)
            guard Set(ids).count == ids.count, optionIDs.isDisjoint(with: ids) else { return false }
            seen.insert(strategy.kind)
            optionIDs.formUnion(ids)
            return true
        }
        self.strategies = Dictionary(uniqueKeysWithValues: usable.map { ($0.kind, $0) })
        kinds = usable.map(\.kind)
    }

    /// The kind a workspace uses when nothing valid is chosen: the first registered one.
    var defaultKind: LayoutKind { kinds.first ?? .free }

    /// The kind after `kind` in registration order, wrapping; the first kind for one that is not registered.
    func kind(after kind: LayoutKind) -> LayoutKind {
        guard let index = kinds.firstIndex(of: kind) else { return defaultKind }
        return kinds[(index + 1) % kinds.count]
    }

    subscript(kind: LayoutKind) -> (any LayoutStrategy)? { strategies[kind] }

    /// The option with this id, whichever kind declares it.
    func option(id: String) -> LayoutOption? {
        for kind in kinds {
            if let option = strategies[kind]?.options.first(where: { $0.id == id }) { return option }
        }
        return nil
    }

    /// The kinds that assign layouts from the layout library, in registration order.
    var libraryKinds: [LayoutKind] { kinds.filter { strategies[$0]?.usesLayoutLibrary == true } }

    /// The commands every registered strategy adds, in registration order, a repeated id counted once.
    var commandSpecs: [LayoutCommandSpec] {
        var seen = Set<String>()
        return kinds.flatMap { strategies[$0]?.commands ?? [] }.filter { seen.insert($0.id).inserted }
    }

    func contains(_ kind: LayoutKind) -> Bool { strategies[kind] != nil }

    /// The configuration of every strategy that has one.
    func configs(_ environment: LayoutEnvironment) -> [LayoutKind: AnyLayoutConfig] {
        var result: [LayoutKind: AnyLayoutConfig] = [:]
        for (kind, strategy) in strategies {
            if let config = strategy.makeConfig(environment) { result[kind] = config }
        }
        return result
    }

    /// The state stored under a kind's name: decoded by its strategy, kept opaque for a kind this build does not
    /// know, dropped (`nil`) when a known kind does not decode.
    func decode(kindName: String, json: JSONValue) -> AnyLayoutState? {
        guard let strategy = strategies[LayoutKind(kindName)] else {
            return AnyLayoutState(OpaqueLayoutState(json: json))
        }
        return strategy.decode(json)
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
                } else if !state.isEmpty {
                    json = strategies[LayoutKind(name)]?.encode(state)
                } else {
                    json = nil
                }
                if let json { result[workspace, default: [:]][name] = json }
            }
        }
        return result
    }
}

// MARK: Shared navigation verbs

/// The two verbs every arranged kind may answer: move the focus to a neighbour, move the window to a neighbour.
extension LayoutCommand {
    /// The ids are namespaced strings (the payload is opaque JSON): the trade-off is documented in
    /// `docs/windows-plugin.md`. Kind-specific ids carry the kind's name (`tiling.join`, `zones.slot`).
    static let focusID = "layout.focus"
    static let moveID = "layout.move"

    static func focus(_ direction: LayoutDirection) -> LayoutCommand { LayoutCommand(focusID, encoding: direction) }
    static func move(_ direction: LayoutDirection) -> LayoutCommand { LayoutCommand(moveID, encoding: direction) }

    /// The direction a `focus` or `move` command carries.
    var direction: LayoutDirection? { payload(as: LayoutDirection.self) }
}

extension EngineCommand {
    /// Moves the focus to the neighbouring tile or zone of the focused window.
    static func focusDirection(_ direction: LayoutDirection) -> EngineCommand { .layout(.focus(direction)) }
    /// Moves the focused window to the neighbouring tile or zone.
    static func moveDirection(_ direction: LayoutDirection) -> EngineCommand { .layout(.move(direction)) }
}
