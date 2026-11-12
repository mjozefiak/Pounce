import Foundation
import LintelKit

/// The one-time move of the default shortcuts to the v2 set (window management v2, step 1.1).
///
/// `HotkeyService.syncCommands` stores a command's default shortcut once and never looks at it again, so everyone who
/// switched the plugin on in v1 has H J K L and ⌥/ (*Toggle Layout*) stored as if they were their own choice. This
/// moves exactly those: a command whose shortcut is still equal to the old default gets the new one (or none); a
/// shortcut the user changed is never touched, and nothing is bound to a key another command holds. It runs through
/// the plugin context (`commandShortcut` / `setCommandShortcut`), once, marked by
/// `plugins.windows.shortcutDefaultsVersion`. It does not depend on whether `syncCommands` ran first: the end state
/// has one owner for each key either way.
@MainActor
struct ShortcutMigration {
    /// One v1 → v2 change of a command's default.
    struct Step: Equatable {
        var id: String
        var old: KeyShortcut
        var new: KeyShortcut?
    }

    /// The commands whose default shortcut differs between v1 and v2 (the table of the spec's Proposed Solution).
    static let steps: [Step] = {
        let option: KeyShortcut.Modifiers = [.option]
        let optionShift: KeyShortcut.Modifiers = [.option, .shift]
        func step(_ id: String, _ key: String, _ modifiers: KeyShortcut.Modifiers, to new: String?) -> Step {
            Step(
                id: id, old: KeyShortcut(key: key, modifiers: modifiers),
                new: new.map { KeyShortcut(key: $0, modifiers: modifiers) })
        }
        return [
            step(WindowsCommandID.focus(.left), "h", option, to: "j"),
            step(WindowsCommandID.focus(.right), "l", option, to: "k"),
            step(WindowsCommandID.focus(.up), "k", option, to: nil),
            step(WindowsCommandID.focus(.down), "j", option, to: nil),
            step(WindowsCommandID.move(.left), "h", optionShift, to: "j"),
            step(WindowsCommandID.move(.right), "l", optionShift, to: "k"),
            step(WindowsCommandID.move(.up), "k", optionShift, to: nil),
            step(WindowsCommandID.move(.down), "j", optionShift, to: nil),
            Step(
                id: WindowsCommandID.toggleLayout, old: KeyShortcut(key: "/", modifiers: option), new: nil),
        ]
    }()

    /// Every command a shortcut may be found on, for the "nobody else holds it" check.
    let commandIDs: [String]
    let shortcut: (String) -> KeyShortcut?
    let setShortcut: (String, KeyShortcut?) -> Void

    /// Runs the migration when `version` is older than the current one and returns the version to store.
    func run(from version: Int) -> Int {
        guard version < WindowsSettings.currentShortcutDefaultsVersion else { return version }
        // Free every key that still holds an old default first, so a key that moves to another command is free
        // when it is assigned (⌥K: `focus.up` → `focus.right`).
        let unchanged = Self.steps.filter { shortcut($0.id) == $0.old }
        for step in unchanged { setShortcut(step.id, nil) }
        for step in unchanged {
            guard let new = step.new else { continue }
            let taken = commandIDs.contains { $0 != step.id && shortcut($0) == new }
            if !taken { setShortcut(step.id, new) }
        }
        return WindowsSettings.currentShortcutDefaultsVersion
    }
}
