import Foundation

/// Stable identifier of a plugin (`apps`, `files`, `clipboard`).
///
/// It is persisted in item keys, in `Plugins/<id>/` paths and in `plugins.<id>.*` settings keys, so an
/// existing value never changes (risk R4, `BACKWARD_COMPATIBILITY.md` section 1).
public struct PluginID: RawRepresentable, Hashable, Comparable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    public static func < (lhs: PluginID, rhs: PluginID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Identifier of one search source inside a plugin, for logging and section ordering.
public struct SourceID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

/// Key of a rankable item in the persisted format `<plugin id>:<key>` (for example `apps:<bundle ID>`
/// or `files:<path>`). The format is a protected contract (risk R4).
public struct ItemKey: Hashable, Sendable, CustomStringConvertible {
    public let pluginID: PluginID
    public let key: String

    public init(pluginID: PluginID, key: String) {
        self.pluginID = pluginID
        self.key = key
    }

    /// Parses `<plugin id>:<key>`. Returns `nil` when there is no separator or either part is empty.
    /// Only the first `:` separates the parts, so keys such as file paths may contain `:`.
    public init?(rawValue: String) {
        guard let separator = rawValue.firstIndex(of: ":") else { return nil }
        let id = rawValue[..<separator]
        let key = rawValue[rawValue.index(after: separator)...]
        guard !id.isEmpty, !key.isEmpty else { return nil }
        self.init(pluginID: PluginID(rawValue: String(id)), key: String(key))
    }

    public var rawValue: String { "\(pluginID.rawValue):\(key)" }

    public var description: String { rawValue }
}

/// Identifier of a panel mode contributed by a plugin (for example the clipboard list).
public struct PanelModeID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}
