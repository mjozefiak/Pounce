import Foundation
import LintelKit

/// The words of the warning about shortcuts that type a character on the active keyboard layout, in one place for the
/// banner at the top of the pane, the welcome step and the row in Advanced (spec v2, Phase 0, step 0.5). Pure: the
/// shortcuts come from `ShortcutSafety`.
enum ShortcutWarning {
    /// How many keys the text names before it says "and N more".
    static let namedKeys = 3

    /// "⌥K", "⌥⇧1": the modifiers in the order the system prints them, then the key.
    static func name(of shortcut: KeyShortcut) -> String {
        let modifiers = shortcut.modifiers
        return (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
            + shortcut.key.uppercased()
    }

    /// "⌥K, ⌥1, ⌥2" (the first `namedKeys`).
    static func names(_ shortcuts: [KeyShortcut]) -> String {
        shortcuts.prefix(namedKeys).map(name(of:)).joined(separator: ", ")
    }

    static func title(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "\(count) shortcuts type letters", comment: "Window Management shortcut warning: how many shortcuts type")
    }

    static func detail(_ shortcuts: [KeyShortcut]) -> LocalizedStringResource {
        let names = names(shortcuts)
        if shortcuts.count == 1 {
            return LocalizedStringResource(
                "\(names) types a character on this keyboard layout.",
                comment: "Window Management shortcut warning: names the keys")
        }
        if shortcuts.count <= namedKeys {
            return LocalizedStringResource(
                "\(names) type characters on this keyboard layout.",
                comment: "Window Management shortcut warning: names the keys")
        }
        let more = shortcuts.count - namedKeys
        return LocalizedStringResource(
            "\(names) and \(more) more type characters on this keyboard layout.",
            comment: "Window Management shortcut warning: names the first keys and counts the rest")
    }

    static let action = LocalizedStringResource(
        "Use ⌃⌥ for these", comment: "Window Management shortcut warning button: changes only the flagged shortcuts")
}
