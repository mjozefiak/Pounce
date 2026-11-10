import AppsPlugin
import ClipboardPlugin
import DictationPlugin
import FilesPlugin
import LintelKit
import MeetingsPlugin
import NotesPlugin

/// The only place that knows the concrete plugins. Adding a feature means a new target, a `LintelApp`
/// dependency on it and one line in this list.
enum PluginRegistry {
    static let all: [any LintelPlugin.Type] = {
        [
            AppsPlugin.self,
            FilesPlugin.self,
            ClipboardPlugin.self,
            DictationPlugin.self,
            MeetingsPlugin.self,
            // Registered in every build since step 7.1 of the Notes spec (`2026-11-04-notes-workspace`).
            NotesPlugin.self,
        ]
    }()
}
