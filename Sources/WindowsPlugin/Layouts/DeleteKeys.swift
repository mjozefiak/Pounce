import SwiftUI

/// Which key presses mean "delete" for the Layouts window's matrix and the grid editor. A Mac's Backspace key
/// (labelled Delete) sends U+007F, older paths U+0008, and forward delete U+F728; `KeyEquivalent.delete` and
/// `.deleteForward` did not match every one of them on a real keyboard (QA: Backspace did nothing, forward delete
/// worked), so the characters are checked too.
enum DeleteKeys {
    static let characters: Set<Unicode.Scalar> = ["\u{7F}", "\u{8}", "\u{F728}"]

    static func isDelete(key: KeyEquivalent, characters typed: String) -> Bool {
        if key == .delete || key == .deleteForward { return true }
        return typed.unicodeScalars.contains { characters.contains($0) }
    }
}
