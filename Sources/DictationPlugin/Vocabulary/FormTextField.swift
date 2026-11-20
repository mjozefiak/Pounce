import AppKit
import LintelUI
import SwiftUI

/// A single-line text field for the Vocabulary form with the keys the form needs: Return, Escape and Backspace in
/// an empty field. SwiftUI's `TextField` hands none of them over reliably, so this is an `NSTextField` with no
/// border (the form draws it) that reports focus changes and takes focus when the model asks.
struct FormTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let size: CGFloat
    /// `true` while the model wants this field to have the keyboard; `focusTick` changes on every request.
    let wantsFocus: Bool
    let focusTick: Int
    var onReturn: () -> Void = {}
    var onEscape: () -> Void = {}
    var onBackspaceWhenEmpty: () -> Void = {}
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> FocusReportingTextField {
        let field = FocusReportingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.onFocusChange(focused)
        }
        return field
    }

    func updateNSView(_ field: FocusReportingTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.font = NSFont.systemFont(ofSize: size)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: LintelBrand.secondaryTextColor, .font: NSFont.systemFont(ofSize: size)])
        field.setAccessibilityLabel(accessibilityLabel)
        if wantsFocus, context.coordinator.handledTick != focusTick {
            context.coordinator.handledTick = focusTick
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusReportingTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 140, height: ceil(size * 1.35))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FormTextField
        var handledTick = -1

        init(_ parent: FormTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onReturn()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                guard textView.string.isEmpty else { return false }
                parent.onBackspaceWhenEmpty()
                return true
            default:
                return false
            }
        }
    }
}

/// An `NSTextField` that says when it gains or loses the keyboard.
final class FocusReportingTextField: NSTextField {
    var onFocusChange: (Bool) -> Void = { _ in }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChange(true) }
        return result
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange(false)
    }
}
