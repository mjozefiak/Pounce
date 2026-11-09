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

/// The overrides of one workspace; every field that is `nil` falls back to the global default (Q17).
struct WorkspaceOverride: Equatable, Sendable {
    var kind: LayoutKind?
    var innerGap: Int?
    var outerGap: Int?
    var rootOrientation: TilingOrientation?

    var isEmpty: Bool { kind == nil && innerGap == nil && outerGap == nil && rootOrientation == nil }
}

/// What one workspace uses after the overrides are applied to the defaults.
struct ResolvedLayout: Equatable, Sendable {
    var kind: LayoutKind
    var gaps: TilingGaps
    var rootOrientation: TilingOrientation
}

/// The global defaults and the per-workspace overrides, as the engine needs them. The struct's own defaults are
/// the engine's (Free: nothing is arranged until a caller opts in); the plugin builds the real values from the
/// settings, where the default kind is Auto-tile.
struct LayoutConfig: Equatable, Sendable {
    var defaultKind: LayoutKind = .free
    var innerGap = WindowsSettings.defaultInnerGap
    var outerGap = WindowsSettings.defaultOuterGap
    var rootOrientation: TilingOrientation = .horizontal
    var overrides: [WorkspaceID: WorkspaceOverride] = [:]

    /// The same configuration with every kind this build has no strategy for replaced: the default by the
    /// registry's default kind, an override's kind by "no override" (the global value applies).
    func sanitized(by registry: LayoutRegistry) -> LayoutConfig {
        var config = self
        if !registry.contains(config.defaultKind) { config.defaultKind = registry.defaultKind }
        for (workspace, override) in config.overrides {
            guard let kind = override.kind, !registry.contains(kind) else { continue }
            var cleaned = override
            cleaned.kind = nil
            config.overrides[workspace] = cleaned.isEmpty ? nil : cleaned
        }
        return config
    }

    func resolved(for workspace: WorkspaceID) -> ResolvedLayout {
        let override = overrides[workspace]
        return ResolvedLayout(
            kind: override?.kind ?? defaultKind,
            gaps: TilingGaps(
                inner: CGFloat(override?.innerGap ?? innerGap), outer: CGFloat(override?.outerGap ?? outerGap)),
            rootOrientation: override?.rootOrientation ?? rootOrientation)
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

    private struct Record: Codable {
        var version: Int
        var workspaces: [String: Entry]

        struct Entry: Codable {
            var kind: String?
            var innerGap: Int?
            var outerGap: Int?
            var rootOrientation: String?
        }
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
            let override = WorkspaceOverride(
                kind: entry.kind.map { LayoutKind($0) },
                innerGap: entry.innerGap.map(WindowsSettings.clampGap),
                outerGap: entry.outerGap.map(WindowsSettings.clampGap),
                rootOrientation: entry.rootOrientation.flatMap(TilingOrientation.init(rawValue:)))
            if !override.isEmpty { byWorkspace[workspace] = override }
        }
    }

    /// The JSON to store; empty overrides give an empty string (the setting is then cleared).
    var json: String {
        let entries = byWorkspace.filter { !$0.value.isEmpty }
        guard !entries.isEmpty else { return "" }
        let record = Record(
            version: Self.version,
            workspaces: Dictionary(
                uniqueKeysWithValues: entries.map {
                    (
                        String($0.key.rawValue),
                        Record.Entry(
                            kind: $0.value.kind?.rawValue, innerGap: $0.value.innerGap, outerGap: $0.value.outerGap,
                            rootOrientation: $0.value.rootOrientation?.rawValue)
                    )
                }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record), let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }
}
