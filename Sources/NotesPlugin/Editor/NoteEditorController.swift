import AppKit
import LintelCore
import LintelKit
import LintelUI

/// What the editor reports after the user changed the text. `text` is the whole Markdown source after the
/// change; the range says what the change touched (the new text of the changed range).
struct NoteEditorEdit: Equatable, Sendable {
    var text: String
    /// The changed range in the new text (UTF-16 offsets) and how much the length changed.
    var range: Range<Int>
    var changeInLength: Int
}

/// Owns the editor's text view, styler and format actions. UI-free: the SwiftUI wrapper and the tests both drive
/// it, so the configuration, the restyle and the pasteboard are tested without a window. The editor does not
/// save: it holds the buffer and reports every edit through `onEdit`; step 4.2 connects that to the revisions.
@MainActor
final class NoteEditorController: NSObject, NSTextStorageDelegate, NSTextViewDelegate {
    let textView: NoteEditorTextView
    let styler: NoteEditorStyler
    /// The user changed the text (typing, paste, a format action, undo). Never called for `setText`.
    var onEdit: (NoteEditorEdit) -> Void = { _ in }
    /// The editor gained or lost focus (a save point, spec "Saving").
    var onFocusChange: (Bool) -> Void = { _ in }

    /// The author gutter beside the text (the scroll view's ruler), set by the SwiftUI wrapper.
    var gutter: AuthorGutterRuler?
    /// Who wrote each block of the buffer, asked with the blocks of the current text (spec step 4.3); `nil` draws
    /// no gutter. It runs on every change, so it stays a dictionary lookup per block.
    var attribution: (([String]) -> [BlockAttributionInfo])? {
        didSet { refreshGutter() }
    }

    private let pasteboard: any PasteboardClient
    private var isReplacingText = false

    init(pasteboard: any PasteboardClient, textSize: TextSize = .default, isReadOnly: Bool = false) {
        self.pasteboard = pasteboard
        textView = NoteEditorTextView.make()
        styler = NoteEditorStyler(theme: NoteEditorTheme(textSize: textSize))
        super.init()
        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.copyText = { [pasteboard] text in NoteClipboard.copy(text, to: pasteboard) }
        textView.formatShortcut = { [weak self] action in self?.perform(action) }
        textView.typingAttributes = styler.theme.baseAttributes
        textView.insertionPointColor = LintelBrand.accentColor
        textView.selectedTextAttributes = [.backgroundColor: LintelBrand.windowSelectionTintColor]
        self.isReadOnly = isReadOnly
    }

    var isReadOnly: Bool {
        get { !textView.isEditable }
        set { textView.isEditable = !newValue }
    }

    var text: String { textView.string }

    /// Replaces the whole text (opening a note, Restore): styled in full, the undo stack cleared, no `onEdit`.
    func setText(_ text: String) {
        guard let storage = textView.textStorage else { return }
        isReplacingText = true
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        styler.restyleAll(storage)
        isReplacingText = false
        textView.undoManager?.removeAllActions()
        textView.typingAttributes = styler.theme.baseAttributes
        refreshGutter()
    }

    /// Locates every block of the buffer and hands the gutter its author. Called after the text changed.
    func refreshGutter() {
        guard let gutter else { return }
        guard let attribution else {
            gutter.blocks = []
            return
        }
        let text = textView.string
        let blocks = MarkdownBlocks.split(text)
        let infos = attribution(blocks)
        let ranges = BlockLocator.ranges(of: blocks, in: text)
        gutter.blocks = zip(infos, ranges).compactMap { info, range in
            range.map { AuthorGutterRuler.Block(range: $0, info: info) }
        }
    }

    func setTextSize(_ size: TextSize) {
        guard size != styler.theme.textSize, let storage = textView.textStorage else { return }
        styler.setTheme(NoteEditorTheme(textSize: size), storage: storage)
        textView.typingAttributes = styler.theme.baseAttributes
    }

    func setWrapsLines(_ wraps: Bool) {
        guard let container = textView.textContainer else { return }
        textView.isHorizontallyResizable = !wraps
        container.widthTracksTextView = wraps
        container.size = NSSize(
            width: wraps ? textView.bounds.width : CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = wraps ? [.width] : []
    }

    // MARK: Format actions

    /// A format-bar button or ⌘B / ⌘I: one ordinary edit, so Undo takes it back as one step. Does nothing while
    /// the editor is read-only.
    @discardableResult
    func perform(_ action: NoteFormatAction) -> Bool {
        guard !isReadOnly else { return false }
        let selection = textView.selectedRange()
        guard
            let edit = MarkdownFormatting.edit(
                action, in: textView.string, selection: selection.location..<(selection.location + selection.length))
        else { return false }
        let range = NSRange(edit.range)
        guard textView.shouldChangeText(in: range, replacementString: edit.replacement) else { return false }
        textView.replaceCharacters(in: range, with: edit.replacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(edit.selection))
        return true
    }

    // MARK: NSTextStorageDelegate

    nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            guard !isReplacingText, let storage = textView.textStorage else { return }
            styler.restyle(storage, edited: editedRange, changeInLength: delta)
            lastEdit = (editedRange, delta)
        }
    }

    private var lastEdit: (range: NSRange, delta: Int)?

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isReplacingText, let edit = lastEdit else { return }
        lastEdit = nil
        refreshGutter()
        onEdit(
            NoteEditorEdit(
                text: textView.string, range: edit.range.location..<(edit.range.location + edit.range.length),
                changeInLength: edit.delta))
    }

    func textDidBeginEditing(_ notification: Notification) { onFocusChange(true) }

    func textDidEndEditing(_ notification: Notification) { onFocusChange(false) }
}
