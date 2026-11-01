import AppKit

/// A regular shell window (Settings, the first-launch Shortcut step). Pounce is an agent app without a
/// main menu, so the standard Close (Command-W) key equivalent has no menu item to fire; the window
/// handles it itself. A global main menu is avoided on purpose: its Quit (Command-Q) would also fire
/// while the launcher panel has focus.
final class ShellWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isClose(event) {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Command-W, with no other modifier.
    static func isClose(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "w"
    }
}
