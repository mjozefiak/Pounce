import CoreGraphics
import Foundation
import LintelKit

/// What decides how a workspace is arranged (spec Q5): an open identifier, so a new strategy is a new type and one
/// registry line (`LayoutRegistry`). The raw values are the strings of the `plugins.windows.defaultKind` setting,
/// of the per-workspace overrides and of the state keys in `state.json`. Auto-tile, Zones and Free are the standard
/// ones.
struct LayoutKind: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    init(_ rawValue: String) { self.rawValue = rawValue }

    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let tiling = LayoutKind("tiling")
    static let zones = LayoutKind("zones")
    static let free = LayoutKind("free")

}

/// The overrides of one workspace; every field that is `nil` or absent falls back to the global default (Q17).
/// The options are the values of the kind's own settings (`LayoutOption`), kept without interpreting them, so a
/// value for a kind that is not the one in use (or from a later version) survives a change of kind.
struct WorkspaceOverride: Equatable, Sendable {
    var kind: LayoutKind?
    var options: [String: JSONValue] = [:]

    var isEmpty: Bool { kind == nil && options.isEmpty }
}

/// What one workspace uses after the overrides are applied to the defaults: its kind and the value of every
/// option of that kind (read back by the strategy: `ResolvedLayout.int(_:)`, `string(_:)`).
struct ResolvedLayout: Equatable, Sendable {
    var kind: LayoutKind
    var options: [String: JSONValue] = [:]
}

/// The global defaults and the per-workspace overrides, as the engine needs them. The struct's own defaults are
/// the engine's (Free: nothing is arranged until a caller opts in); `init(settings:registry:)` is the one place that
/// builds the real values (the engine configuration and the pane both use it), where the default kind is the
/// registry's first.
struct LayoutConfig: Equatable, Sendable {
    var defaultKind: LayoutKind = .free
    /// The global value of every option of every registered kind, by kind.
    var optionDefaults: [LayoutKind: [String: JSONValue]] = [:]
    var overrides: [WorkspaceID: WorkspaceOverride] = [:]

    init(
        defaultKind: LayoutKind = .free, optionDefaults: [LayoutKind: [String: JSONValue]] = [:],
        overrides: [WorkspaceID: WorkspaceOverride] = [:]
    ) {
        self.defaultKind = defaultKind
        self.optionDefaults = optionDefaults
        self.overrides = overrides
    }

    /// The configuration the settings describe, for the kinds of `registry`: the default kind, every option's
    /// global value and the stored overrides (`overrides` replaces them when the caller already holds them),
    /// sanitized by the registry.
    init(settings: WindowsSettings, registry: LayoutRegistry, overrides: [WorkspaceID: WorkspaceOverride]? = nil) {
        var defaults: [LayoutKind: [String: JSONValue]] = [:]
        for kind in registry.kinds {
            for option in registry[kind]?.options ?? [] {
                defaults[kind, default: [:]][option.id] = settings.globalValue(of: option)
            }
        }
        self.init(
            defaultKind: settings.defaultKind(in: registry), optionDefaults: defaults,
            overrides: overrides ?? settings.workspaceOverrides.byWorkspace)
        self = sanitized(by: registry)
    }

    /// The same configuration with what this build cannot use dropped: the default kind it has no strategy for is
    /// replaced by the registry's default kind, an override's kind it has no strategy for by "no override" (the
    /// global value applies), and an option value that is not valid for its option by "no override".
    func sanitized(by registry: LayoutRegistry) -> LayoutConfig {
        var config = self
        if !registry.contains(config.defaultKind) { config.defaultKind = registry.defaultKind }
        for (workspace, override) in config.overrides {
            var cleaned = override
            if let kind = override.kind, !registry.contains(kind) { cleaned.kind = nil }
            for (id, value) in override.options {
                if let option = registry.option(id: id) {
                    if let valid = option.valid(value) {
                        cleaned.options[id] = valid
                    } else {
                        cleaned.options[id] = nil
                    }
                }
            }
            config.overrides[workspace] = cleaned.isEmpty ? nil : cleaned
        }
        return config
    }

    func resolved(for workspace: WorkspaceID) -> ResolvedLayout {
        let override = overrides[workspace]
        let kind = override?.kind ?? defaultKind
        var options = optionDefaults[kind] ?? [:]
        // Only the options of the kind in use: another kind's values stay stored but do not apply.
        for (id, value) in override?.options ?? [:] where options[id] != nil { options[id] = value }
        return ResolvedLayout(kind: kind, options: options)
    }
}

/// The versioned JSON value of `plugins.windows.workspaces` (spec: Data Model): the overrides of every workspace
/// in one setting instead of 36 protected keys. A value from a newer version is read as "no overrides" and never
/// overwritten, so a downgrade cannot destroy it; a damaged value reads as "no overrides" and may be replaced.
struct WorkspaceOverrides: Equatable, Sendable {
    static let version = 1

    var byWorkspace: [WorkspaceID: WorkspaceOverride] = [:]
    /// The stored value is from a newer version: nothing may be written over it.
    private(set) var isReadOnly = false

    init(_ byWorkspace: [WorkspaceID: WorkspaceOverride] = [:]) {
        self.byWorkspace = byWorkspace
    }

    /// One stored record: `kind` and the options of the kinds, flat (the shape of the first version, whose options
    /// were `innerGap`, `outerGap` and `rootOrientation`).
    private struct Record: Codable {
        var version: Int
        var workspaces: [String: [String: JSONValue]]
    }

    /// Reads a stored value; `nil` or empty text is "no overrides".
    init(json: String?) {
        guard let json, !json.isEmpty else { return }
        struct Header: Decodable { var version: Int }
        guard let data = json.data(using: .utf8) else { return }
        // Only a newer version is protected. A value that does not parse is damaged: it reads as no overrides and
        // the next change replaces it.
        if let header = try? JSONDecoder().decode(Header.self, from: data), header.version > Self.version {
            isReadOnly = true
            return
        }
        guard let record = try? JSONDecoder().decode(Record.self, from: data), record.version >= 1 else { return }
        for (key, entry) in record.workspaces {
            guard let number = Int(key), let workspace = WorkspaceID(number) else { continue }
            var override = WorkspaceOverride()
            for (name, value) in entry {
                if name == Self.kindKey {
                    if case .string(let kind) = value { override.kind = LayoutKind(kind) }
                } else if value != .null {
                    override.options[name] = value
                }
            }
            if !override.isEmpty { byWorkspace[workspace] = override }
        }
    }

    static let kindKey = "kind"

    /// The JSON to store; empty overrides give an empty string (the setting is then cleared).
    var json: String {
        let entries = byWorkspace.filter { !$0.value.isEmpty }
        guard !entries.isEmpty else { return "" }
        var workspaces: [String: [String: JSONValue]] = [:]
        for (workspace, override) in entries {
            var entry = override.options
            if let kind = override.kind { entry[Self.kindKey] = .string(kind.rawValue) }
            workspaces[String(workspace.rawValue)] = entry
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Record(version: Self.version, workspaces: workspaces)),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }
}
