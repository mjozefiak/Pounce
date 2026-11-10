import AppKit
import SwiftUI

/// Closing a tab with the middle button (the scroll-wheel click), as in a browser.
enum NoteTabMiddleClick {
    /// AppKit numbers the buttons 0 left, 1 right, 2 the middle one.
    static let middleButton = 2

    /// Whether a mouse-up of this button closes a tab.
    static func closes(buttonNumber: Int) -> Bool { buttonNumber == middleButton }
}

extension NotesWorkspaceModel {
    /// The middle button was released on a tab. It does exactly what the tab's × and ⌘W do (`close`), so the
    /// run for a note the agent is writing is cancelled in the same way. Returns whether the event was used.
    @discardableResult
    func handleTabOtherMouseUp(_ id: NoteItemID, buttonNumber: Int) -> Bool {
        guard NoteTabMiddleClick.closes(buttonNumber: buttonNumber), tabs.contains(id) else { return false }
        close(id)
        return true
    }
}

/// A transparent overlay that receives only middle-button events. Every other event (clicks, drags, scrolls,
/// hover) finds no view here and goes to the tab under it, so the tab's buttons and its drag keep working.
struct NoteTabMiddleClickArea: NSViewRepresentable {
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onMiddleClick = onMiddleClick
    }

    final class CatcherView: NSView {
        var onMiddleClick: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                return event.buttonNumber == NoteTabMiddleClick.middleButton ? super.hitTest(point) : nil
            default:
                return nil
            }
        }

        override func otherMouseUp(with event: NSEvent) {
            if NoteTabMiddleClick.closes(buttonNumber: event.buttonNumber) {
                onMiddleClick()
            } else {
                super.otherMouseUp(with: event)
            }
        }

        override var acceptsFirstResponder: Bool { false }
    }
}
