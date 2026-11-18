import AppKit
import Foundation

extension WindowEngine {
    /// The system's left mouse button, read from `NSEvent`'s class property on the main actor. It needs no permission
    /// (unlike a global event monitor), and it is only read while a resize by hand waits to settle.
    @Sendable static func systemLeftButtonDown() async -> Bool {
        await MainActor.run { NSEvent.pressedMouseButtons & 1 != 0 }
    }
}
