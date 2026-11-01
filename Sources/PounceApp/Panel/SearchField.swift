import AppKit
import SwiftUI

/// The search field: an `NSTextField`, so the keyboard table is driven by the field editor's commands.
/// The field editor only sends `insertNewline:` and the arrow commands when no IME composition is in
/// progress, which gives the spec's priority: IME composition, then text editing, then actions.
struct SearchField: NSViewRepresentable {
    let model: PanelModel
    let onCreate: (NSTextField) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isBezeled = false
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = String(localized: "Search", comment: "Placeholder of the panel's search field")
        field.setAccessibilityLabel(String(localized: "Search", comment: "Placeholder of the panel's search field"))
        field.font = model.textSize.nsFont(.title2)
        field.delegate = context.coordinator
        onCreate(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let editor = field.currentEditor() as? NSTextView
        if field.stringValue != model.query, editor?.hasMarkedText() != true {
            field.stringValue = model.query
            // A query set from outside the field (cleared by Esc, or a QA launch) leaves the caret at the
            // end instead of selecting the text.
            editor?.selectedRange = NSRange(location: (model.query as NSString).length, length: 0)
        }
        let font = model.textSize.nsFont(.title2)
        if field.font != font {
            field.font = font
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: PanelModel

        init(model: PanelModel) {
            self.model = model
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // Marked (uncommitted IME) text is not a query yet.
            if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true {
                return
            }
            model.updateQuery(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() {
                return false
            }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                model.moveSelection(by: -1)
            case #selector(NSResponder.moveDown(_:)):
                model.moveSelection(by: 1)
            case #selector(NSResponder.insertNewline(_:)):
                model.performPrimary()
            case #selector(NSResponder.cancelOperation(_:)):
                model.escape()
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                // Focus stays in the field.
                break
            default:
                return false
            }
            return true
        }
    }
}
