import CoreFoundation
import Foundation

/// Reads the system's symbolic hotkeys (`com.apple.symbolichotkeys`, `AppleSymbolicHotKeys`) to find
/// out whether Spotlight holds Command-Space. Carbon reports no error when a hotkey conflicts, so a
/// failed registration cannot tell. Read-only: Pounce never writes this domain.
nonisolated enum SymbolicHotkeys {
    /// "Show Spotlight search".
    static let spotlightSearch = 64
    /// "Show Finder search window".
    static let finderSearchWindow = 65

    /// The macOS defaults used when an entry is missing from the domain.
    static let systemDefaults: [Int: HotkeyShortcut] = [
        spotlightSearch: .commandSpace,
        finderSearchWindow: .optionCommandSpace,
    ]

    struct Entry: Equatable {
        let enabled: Bool
        /// Whether the entry carries its own key parameters; without them the system default applies.
        let hasValue: Bool
        /// `nil` when there is no value or the key is unassigned (key code `0xFFFF`).
        let shortcut: HotkeyShortcut?
    }

    /// Parses one entry: `{ enabled = 1; value = { parameters = (32, 49, 1048576); type = standard; } }`.
    static func entry(_ object: Any?) -> Entry? {
        guard let dictionary = object as? [String: Any] else { return nil }
        let enabled = (dictionary["enabled"] as? NSNumber)?.boolValue ?? false
        var shortcut: HotkeyShortcut?
        var hasValue = false
        if let value = dictionary["value"] as? [String: Any],
            let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3
        {
            hasValue = true
            let keyCode = parameters[1].intValue
            if keyCode != 0xFFFF {
                shortcut = HotkeyShortcut(
                    carbonKeyCode: keyCode,
                    carbonModifiers: HotkeyShortcut.carbonModifiers(fromEventFlags: parameters[2].intValue)
                )
            }
        }
        return Entry(enabled: enabled, hasValue: hasValue, shortcut: shortcut)
    }

    /// The shortcuts held by Spotlight (64) and the Finder search window (65). A missing entry, or an
    /// enabled one without key parameters, means the system default is active; a disabled entry or an
    /// unassigned key holds nothing.
    static func occupiedShortcuts(_ hotkeys: [String: Any]?) -> Set<HotkeyShortcut> {
        var occupied = Set<HotkeyShortcut>()
        for id in [spotlightSearch, finderSearchWindow] {
            guard let entry = entry(hotkeys?[String(id)]) else {
                if let fallback = systemDefaults[id] {
                    occupied.insert(fallback)
                }
                continue
            }
            guard entry.enabled else { continue }
            if let shortcut = entry.shortcut ?? (entry.hasValue ? nil : systemDefaults[id]) {
                occupied.insert(shortcut)
            }
        }
        return occupied
    }

    /// The current `AppleSymbolicHotKeys` dictionary, read without writing anything.
    static func readSystem() -> [String: Any]? {
        CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
            as? [String: Any]
    }
}
