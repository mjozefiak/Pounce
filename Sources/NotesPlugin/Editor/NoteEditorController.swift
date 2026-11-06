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

    /// The selection or the caret moved (the Comment button's state, a caret inside a comment's highlight).
    var onSelectionChange: (NSRange) -> Void = { _ in }

    /// The scroll view the text view sits in, set by the SwiftUI wrapper (the popover is placed from it).
    weak var scrollView: NSScrollView?

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

    // MARK: Comment highlights (step 5.2)

    private var appliedHighlights: [CommentHighlight] = []
    private var appliedPending: NSRange?

    /// Highlights the quotes of the open comments and, while the popover is open, the passage being commented on.
    /// They are rendering attributes of the layout manager, not attributes of the text: the Markdown storage is
    /// untouched, so the styler, undo and the saved text never see them.
    func setHighlights(_ highlights: [CommentHighlight], pending: NSRange? = nil) {
        guard highlights != appliedHighlights || pending != appliedPending else { return }
        appliedHighlights = highlights
        appliedPending = pending
        guard let manager = textView.textLayoutManager, let content = manager.textContentManager else { return }
        let length = (textView.string as NSString).length
        let whole = manager.documentRange
        for key in [NSAttributedString.Key.backgroundColor, .underlineStyle, .underlineColor] {
            manager.removeRenderingAttribute(key, for: whole)
        }
        func textRange(_ range: NSRange) -> NSTextRange? {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
            guard clamped.length > 0,
                let start = content.location(content.documentRange.location, offsetBy: clamped.location),
                let end = content.location(start, offsetBy: clamped.length)
            else { return nil }
            return NSTextRange(location: start, end: end)
        }
        for highlight in highlights {
            guard let range = textRange(highlight.range) else { continue }
            manager.addRenderingAttribute(
                .backgroundColor,
                value: highlight.isSelected ? LintelBrand.selectionTintColor : LintelBrand.windowSelectionTintColor,
                for: range)
            manager.addRenderingAttribute(
                .underlineStyle, value: NSUnderlineStyle.thick.rawValue, for: range)
            manager.addRenderingAttribute(.underlineColor, value: LintelBrand.accentColor, for: range)
        }
        if let pending, let range = textRange(pending) {
            manager.addRenderingAttribute(.backgroundColor, value: LintelBrand.selectionTintColor, for: range)
        }
        textView.needsDisplay = true
    }

    /// The rectangle of `range` in the scroll view's coordinates, top-left origin, or `nil` without a window.
    func rect(of range: NSRange, in scroll: NSScrollView) -> CGRect? {
        guard let window = textView.window else { return nil }
        let screen = textView.firstRect(forCharacterRange: range, actualRange: nil)
        let local = scroll.convert(window.convertFromScreen(screen), from: nil)
        let y = scroll.isFlipped ? local.minY : scroll.bounds.height - local.maxY
        return CGRect(x: local.minX, y: y, width: local.width, height: local.height)
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

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isReplacingText else { return }
        onSelectionChange(textView.selectedRange())
    }

    func textDidBeginEditing(_ notification: Notification) { onFocusChange(true) }

    func textDidEndEditing(_ notification: Notification) { onFocusChange(false) }
}
