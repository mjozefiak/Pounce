import Carbon.HIToolbox
import Foundation
import LintelKit

/// Which default shortcuts would swallow a typed character on the active keyboard layout (spec Q10). On a Polish
/// layout ⌥L types "ł", so a global ⌥L would make that letter impossible to type; this finds such keys so the
/// welcome step and the pane can name them and offer ⌃⌥ for the whole family.
///
/// The check is a pure function over an injected translation (`KeyTranslation`), so it is tested on plain
/// tables; `SystemKeyTranslation` is the UCKeyTranslate-based implementation for the real layout.
enum ShortcutSafety {
    /// What the layout types for a key code with modifiers held, or `nil` when it types nothing.
    typealias KeyTranslation = @MainActor (_ keyCode: UInt16, _ modifiers: KeyShortcut.Modifiers) -> String?

    struct Result: Equatable {
        /// The shortcuts that type a letter.
        var offending: [KeyShortcut]
        var isSafe: Bool { offending.isEmpty }
    }

    /// ANSI key codes of the keys the plugin binds (the positions, not what the layout prints on them).
    static let keyCodes: [String: UInt16] = [
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38, "k": 40, "l": 37,
        "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
        "y": 16, "z": 6, "\t": 48, "-": 27, "=": 24, "/": 44,
    ]

    /// A shortcut is unsafe when its modifiers are only ⌥ and/or ⇧ (the ones that type characters) and the layout
    /// then types a letter. With ⌃ or ⌘ held no character is typed.
    @MainActor
    static func check(_ shortcuts: [KeyShortcut], translate: KeyTranslation) -> Result {
        var offending: [KeyShortcut] = []
        for shortcut in shortcuts {
            guard !shortcut.modifiers.contains(.control), !shortcut.modifiers.contains(.command),
                let code = keyCodes[shortcut.key.lowercased()],
                let typed = translate(code, shortcut.modifiers), typed.count == 1,
                typed.first?.isLetter == true
            else { continue }
            offending.append(shortcut)
        }
        return Result(offending: offending)
    }

    /// The family with ⌃⌥ in place of its modifiers: the one-click fix.
    static func controlOption(for shortcuts: [KeyShortcut]) -> [KeyShortcut] {
        shortcuts.map {
            var modifiers = $0.modifiers
            modifiers.remove(.option)
            modifiers.insert(.control)
            modifiers.insert(.option)
            return KeyShortcut(key: $0.key, modifiers: modifiers)
        }
    }
}

/// `UCKeyTranslate` over the current keyboard layout.
enum SystemKeyTranslation {
    @MainActor
    static func translate(keyCode: UInt16, modifiers: KeyShortcut.Modifiers) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        // The property is a CFData on every macOS that has it; anything else is no layout to translate with.
        let object = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
        guard CFGetTypeID(object) == CFDataGetTypeID() else { return nil }
        let data = unsafeDowncast(object, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        var carbon: UInt32 = 0
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey >> 8) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey >> 8) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey >> 8) }
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey >> 8) }
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), carbon, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
