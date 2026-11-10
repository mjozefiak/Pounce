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
    /// The settings of this kind: a global default (when an option names a setting) and a per-workspace override,
    /// drawn by the pane and delivered to `arrange` in `LayoutInput.resolved`. Option ids are unique across the
    /// registry (a strategy that repeats an id of an earlier one, or of the plugin's own keys, is left out).
    var options: [LayoutOption] { get }
    /// The commands of this kind (Auto-tile: join, resize, balance; Zones: move to zone N), added to the plugin's
    /// command catalogue next to the shared ones. Ids are `windows.<...>` and never change once shipped.
    var commands: [LayoutCommandSpec] { get }
    /// What the per-workspace summary adds for this kind after its name (Auto-tile: gaps and orientation).
    func summaryParts(_ resolved: ResolvedLayout) -> [String]
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
    // Optional capabilities (`LayoutCapabilities.swift`): a kind that has one returns itself. They are typed
    // requirements with a `nil` default, so the registry and the callers need no dynamic cast.
    /// The kind assigns layouts from the layout library (the Layouts window, layout slots, *Next zone layout*).
    var library: (any LayoutLibraryProviding)? { get }
    /// The kind offers snap targets, so a manual window move may start a drag.
    var snapping: (any SnapTargetProviding)? { get }
    /// The kind adds rows to the pane for settings that are not options.
    var settingRows: (any SettingRowProviding)? { get }
    /// The JSON stored under the kind's name; `nil` for an empty state.
    func encode(_ state: AnyLayoutState) -> JSONValue?
    /// The state a stored JSON describes; `nil` when it does not decode (it is dropped, not a corrupt file).
    func decode(_ json: JSONValue) -> AnyLayoutState?
}

extension LayoutStrategy {
    var displayName: String { kind.rawValue }
    var library: (any LayoutLibraryProviding)? { nil }
    var snapping: (any SnapTargetProviding)? { nil }
    var settingRows: (any SettingRowProviding)? { nil }
    var options: [LayoutOption] { [] }
    var commands: [LayoutCommandSpec] { [] }
    func summaryParts(_ resolved: ResolvedLayout) -> [String] { [] }
    func makeConfig(_ environment: LayoutEnvironment) -> AnyLayoutConfig? { nil }
    func perform(_ command: LayoutCommand, on window: WindowID, _ input: LayoutInput) -> LayoutEdit? { nil }
    func removing(_ window: WindowID, from state: AnyLayoutState) -> AnyLayoutState { state }
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
