import AppsPlugin
import ClipboardPlugin
import FilesPlugin
import PounceKit

/// The only place that knows the concrete plugins. Adding a feature means a new target, a `PounceApp`
/// dependency on it and one line in this list.
enum PluginRegistry {
    static let all: [any PouncePlugin.Type] = [
        AppsPlugin.self,
        FilesPlugin.self,
        ClipboardPlugin.self,
    ]
}
