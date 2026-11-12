import CoreGraphics
import Foundation
import LintelKit

// MARK: Registry

/// The kinds of the standard strategies (`LayoutRegistry.standard`); they are the raw values of the stored settings and
/// state keys, so they never change.
extension LayoutKind {
    static let tiling = LayoutKind("tiling")
    static let zones = LayoutKind("zones")
    static let free = LayoutKind("free")
    static let accordion = LayoutKind("accordion")
}

/// The strategies of this build, by kind. The reducer and the engine take it as an argument, so a test can pass a
/// registry of its own.
struct LayoutRegistry: Sendable {
    static let standard = LayoutRegistry([TilingStrategy(), ZonesStrategy(), FreeStrategy(), AccordionStrategy()])

    private let strategies: [LayoutKind: any LayoutStrategy]
    /// The kinds in registration order: what the pane offers and *Toggle layout* cycles through.
    let kinds: [LayoutKind]

    /// Kind names that cannot be used: they are keys of a workspace record in `state.json` next to the per-kind
    /// state.
    static let reservedKindNames: Set<String> = ["order", WorkspaceOverrides.useDefaultKindName]

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
    var libraryKinds: [LayoutKind] { kinds.filter { strategies[$0]?.library != nil } }

    /// The commands every registered strategy adds, in registration order, a repeated id counted once; one that takes
    /// an id the plugin owns (`WindowsCommandID.reserved`) is left out.
    var commandSpecs: [LayoutCommandSpec] {
        var seen = WindowsCommandID.reserved
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
