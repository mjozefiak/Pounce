import Foundation

/// A direction of the navigation verbs every arranged kind may answer (focus the neighbour, move the window to it).
enum LayoutDirection: String, Codable, Sendable, CaseIterable {
    case left
    case right
    case up
    case down
}

/// One setting of a layout kind that a workspace may override (spec: Architecture, "Strategy pattern for
/// layouts"). The strategy declares its options; the plugin stores the values without knowing what they mean (a
/// global default in `plugins.windows.*` when `settingKey` is set, the per-workspace overrides in
/// `plugins.windows.workspaces`), the pane draws them, and the strategy reads them back from
/// `LayoutInput.resolved`. Option ids are unique across the registry (a strategy that repeats one is left out), so
/// an override record stays flat and a stored value is never ambiguous.
struct LayoutOption: Identifiable, Equatable, Sendable {
    struct Choice: Equatable, Sendable {
        var id: String
        var title: String
    }

    enum Domain: Equatable, Sendable {
        /// A whole number of points.
        case points(ClosedRange<Int>)
        /// One of a fixed list of ids.
        case choices([Choice])
    }

    /// The key of the value in an override record and in `ResolvedLayout.options`.
    var id: String
    var title: String
    var help: String?
    var domain: Domain
    /// The value when nothing is stored.
    var defaultValue: JSONValue
    /// The `plugins.windows.<key>` setting that holds the global default, or `nil` when the option has no global
    /// setting (its default is `defaultValue`).
    var settingKey: String?

    /// The value made valid for the domain, or `nil` when it cannot be (a wrong type, an id that is not offered).
    func valid(_ value: JSONValue?) -> JSONValue? {
        switch (domain, value) {
        case (.points(let range), .int(let number)?):
            return .int(min(range.upperBound, max(range.lowerBound, number)))
        case (.choices(let choices), .string(let text)?):
            return choices.contains { $0.id == text } ? .string(text) : nil
        default:
            return nil
        }
    }

    /// `value` made valid, or the default.
    func resolved(_ value: JSONValue?) -> JSONValue { valid(value) ?? defaultValue }
}

extension ResolvedLayout {
    /// The whole number of an option; `nil` when it is not one.
    func int(_ id: String) -> Int? {
        if case .int(let number)? = options[id] { return number }
        return nil
    }

    /// The text of an option; `nil` when it is not text.
    func string(_ id: String) -> String? {
        if case .string(let text)? = options[id] { return text }
        return nil
    }
}
