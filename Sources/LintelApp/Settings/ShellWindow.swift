import AppKit

/// A regular shell window (Settings, the first-launch Shortcut step). Lintel is an agent app without a
/// main menu, so the standard Close (Command-W) key equivalent has no menu item to fire; the window
/// handles it itself. A global main menu is avoided on purpose: its Quit (Command-Q) would also fire
/// while the launcher panel has focus.
final class ShellWindow: NSWindow {
    /// Command-W goes here first; `true` means it was handled and the window stays as it is (the main window's
    /// Workspace mode asks the section, then closes after `willHide`). The menu has no Close item, so it fires once.
    var closeHandler: (() -> Bool)?
    /// The title bar's close button (`performClose`): `false` keeps the window open (the main window closes it
    /// itself after the section's `willHide`). Not a delegate, so the window never points at a freed object.
    var shouldClose: (() -> Bool)?

    override func performClose(_ sender: Any?) {
        if shouldClose?() == false { return }
        super.performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isClose(event) {
            if closeHandler?() != true { performClose(nil) }
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
