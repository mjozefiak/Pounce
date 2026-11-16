import SwiftUI

/// Which key presses mean "delete" for the Layouts window's matrix and the grid editor. A Mac's Backspace key
/// (labelled Delete) sends U+007F, older paths U+0008, and forward delete U+F728; `KeyEquivalent.delete` and
/// `.deleteForward` did not match every one of them on a real keyboard (QA: Backspace did nothing, forward delete
/// worked), so the characters are checked too.
enum DeleteKeys {
    static let characters: Set<Unicode.Scalar> = ["\u{7F}", "\u{8}", "\u{F728}"]

    /// The one policy for "this key press deletes", used by the matrix and the editor: a delete key (above) with no
    /// modifier that changes its meaning. **Shift is allowed** (Shift+Backspace means Backspace on a Mac keyboard);
    /// **Command, Control and Option are not** (Ctrl+H sends the same U+0008, Cmd+Backspace and Option+Backspace
    /// mean other things); **Caps Lock, Function and the numeric-pad flag are ignored**, since a key press carries
    /// them without the user pressing a modifier (the arrow and delete keys set Function).
    static func isPlainDelete(key: KeyEquivalent, characters typed: String, modifiers: EventModifiers) -> Bool {
        guard meaningful(modifiers).subtracting(.shift).isEmpty else { return false }
        return isDelete(key: key, characters: typed)
    }

    /// The modifiers that change what a key means: a key press also carries Caps Lock, Function and the numeric-pad
    /// flag without the user pressing a modifier, so those are dropped.
    static func meaningful(_ modifiers: EventModifiers) -> EventModifiers {
        modifiers.subtracting([.capsLock, .function, .numericPad])
    }

    static func isDelete(key: KeyEquivalent, characters typed: String) -> Bool {
        if key == .delete || key == .deleteForward { return true }
        return typed.unicodeScalars.contains { characters.contains($0) }
    }
}
