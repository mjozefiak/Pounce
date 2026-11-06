import SwiftUI

/// What a pane shows, found by walking its view tree with `Mirror` and evaluating the `body` of the plugin's own
/// views on the way (SwiftUI's views are only reflected, never evaluated): the localized keys and plain strings,
/// and the full type names (a `ForEach` row's view type is only in its type name).
@MainActor struct PaneText {
    private(set) var keys: Set<String> = []
    private(set) var types: Set<String> = []

    init(_ view: some View, module: String) {
        visit(view, module: module, depth: 0)
    }

    /// Whether the pane shows `token`: a localized key, or `type:Name` for a view type in the tree.
    func shows(_ token: String) -> Bool {
        if token.hasPrefix("type:") {
            let name = token.dropFirst("type:".count)
            return types.contains { $0.contains(name) }
        }
        return keys.contains(token)
    }

    private mutating func visit(_ value: Any, module: String, depth: Int) {
        guard depth < 90 else { return }
        types.insert(String(describing: type(of: value)))
        if let key = value as? LocalizedStringKey,
            let text = Mirror(reflecting: key).children.first(where: { $0.label == "key" })?.value as? String
        {
            keys.insert(text)
        }
        if let resource = value as? LocalizedStringResource {
            keys.insert(resource.key)
        }
        if let text = value as? String {
            keys.insert(text)
        }
        if let view = value as? any View, let body = Self.body(of: view, module: module) {
            visit(body, module: module, depth: depth + 1)
        }
        for child in Mirror(reflecting: value).children {
            visit(child.value, module: module, depth: depth + 1)
        }
    }

    private static func body<V: View>(of view: V, module: String) -> Any? {
        guard V.Body.self != Never.self, String(reflecting: V.self).hasPrefix("\(module).") else { return nil }
        return view.body
    }
}
