import Carbon.HIToolbox
import Foundation
import PounceKit

/// A global shortcut as Carbon key code and modifiers (the format KeyboardShortcuts stores and the
/// system registers).
nonisolated struct HotkeyShortcut: Hashable, Sendable {
    let carbonKeyCode: Int
    let carbonModifiers: Int

    static let commandSpace = HotkeyShortcut(carbonKeyCode: kVK_Space, carbonModifiers: cmdKey)
    static let controlOptionSpace = HotkeyShortcut(carbonKeyCode: kVK_Space, carbonModifiers: controlKey | optionKey)
    static let optionCommandSpace = HotkeyShortcut(carbonKeyCode: kVK_Space, carbonModifiers: cmdKey | optionKey)

    /// Modifiers in the order macOS writes them, then the key.
    var displayString: String {
        var text = ""
        if carbonModifiers & controlKey != 0 { text += "⌃" }
        if carbonModifiers & optionKey != 0 { text += "⌥" }
        if carbonModifiers & shiftKey != 0 { text += "⇧" }
        if carbonModifiers & cmdKey != 0 { text += "⌘" }
        return text + (Self.keyNames[carbonKeyCode] ?? "?")
    }

    /// Converts `NSEvent.ModifierFlags` raw values (as stored in `com.apple.symbolichotkeys`) to Carbon.
    static func carbonModifiers(fromEventFlags flags: Int) -> Int {
        var modifiers = 0
        if flags & (1 << 17) != 0 { modifiers |= shiftKey }
        if flags & (1 << 18) != 0 { modifiers |= controlKey }
        if flags & (1 << 19) != 0 { modifiers |= optionKey }
        if flags & (1 << 20) != 0 { modifiers |= cmdKey }
        return modifiers
    }

    /// A plugin's portable shortcut on the US layout, or `nil` for keys Pounce does not map.
    init?(_ shortcut: KeyShortcut) {
        guard let code = Self.keyCodes[shortcut.key.lowercased()] else { return nil }
        var modifiers = 0
        if shortcut.modifiers.contains(.command) { modifiers |= cmdKey }
        if shortcut.modifiers.contains(.shift) { modifiers |= shiftKey }
        if shortcut.modifiers.contains(.option) { modifiers |= optionKey }
        if shortcut.modifiers.contains(.control) { modifiers |= controlKey }
        self.init(carbonKeyCode: code, carbonModifiers: modifiers)
    }

    init(carbonKeyCode: Int, carbonModifiers: Int) {
        self.carbonKeyCode = carbonKeyCode
        self.carbonModifiers = carbonModifiers
    }

    private static let letterCodes: [Int] = [
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
        kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
        kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
        kVK_ANSI_Y, kVK_ANSI_Z,
    ]
    private static let digitCodes: [Int] = [
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
        kVK_ANSI_8, kVK_ANSI_9,
    ]

    static let keyCodes: [String: Int] = {
        var codes: [String: Int] = [" ": kVK_Space, "\r": kVK_Return, "\t": kVK_Tab]
        for (index, scalar) in "abcdefghijklmnopqrstuvwxyz".unicodeScalars.enumerated() {
            codes[String(scalar)] = letterCodes[index]
        }
        for (index, scalar) in "0123456789".unicodeScalars.enumerated() {
            codes[String(scalar)] = digitCodes[index]
        }
        return codes
    }()

    static let keyNames: [Int: String] = {
        var names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥"]
        for (key, code) in keyCodes where key.count == 1 && key != " " && key != "\r" && key != "\t" {
            names[code] = key.uppercased()
        }
        return names
    }()
}

/// The default main shortcut (Q10): Command-Space, or Control-Option-Space when Spotlight (or anything
/// in the system's symbolic hotkeys) holds Command-Space. Option-Command-Space is never used: it is the
/// Finder search window (symbolic hotkey 65).
nonisolated enum ShortcutPolicy {
    static let candidates: [HotkeyShortcut] = [.commandSpace, .controlOptionSpace]

    static func defaultShortcut(occupied: Set<HotkeyShortcut>) -> HotkeyShortcut {
        candidates.first { !occupied.contains($0) } ?? .controlOptionSpace
    }

    /// What the main shortcut should be: a user-chosen one (even "none") always wins; otherwise the
    /// current default, so ⌃⌥Space becomes ⌘Space once Spotlight releases it.
    static func resolve(current: HotkeyShortcut?, userDefined: Bool, occupied: Set<HotkeyShortcut>)
        -> HotkeyShortcut?
    {
        userDefined ? current : defaultShortcut(occupied: occupied)
    }
}
