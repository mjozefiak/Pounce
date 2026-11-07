import AppKit
import LintelKit

/// The Markdown source editor: an `NSTextView` over TextKit 2 (`NSTextLayoutManager`; nothing here touches
/// `layoutManager`, which would drop it back to TextKit 1). Configured for privacy and for source text:
/// Writing Tools off (no selected text goes to Private Cloud Compute), Services off for the text, no automatic
/// substitutions (the text is Markdown, not prose), plain text only, links inert. Spelling and grammar checking
/// stay on, on this Mac. Copy and cut go through the plugin's pasteboard port (transient and concealed markers,
/// this Mac only), never straight to the general pasteboard.
@MainActor
final class NoteEditorTextView: NSTextView {
    /// Where ⌘C, ⌘X and Copy Markdown from the editor write (`NoteClipboard`, `PluginContext.pasteboard`).
    var copyText: (String) -> Void = { _ in }
    /// The text view drew (the layout it shows is current): the author gutter measures the blocks again.
    var onDraw: () -> Void = {}
    /// ⇧⌘M: comment on the selection (spec: ⌥⌘M is Window → Minimize All), set by the editor view.
    var commentShortcut: (() -> Void)?
    /// ⌘B and ⌘I, set by the controller.
    var formatShortcut: (NoteFormatAction) -> Void = { _ in }

    /// A text view over TextKit 2 with the editor's configuration.
    static func make() -> NoteEditorTextView {
        let view = NoteEditorTextView(usingTextLayoutManager: true)
        view.configure()
        return view
    }

    private func configure() {
        writingToolsBehavior = .none
        allowedWritingToolsResultOptions = []
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        isEditable = true
        isSelectable = true
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        usesFontPanel = false
        usesRuler = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = true
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainerInset = .zero
        setAccessibilityLabel(
            String(localized: "Note text", comment: "Accessibility label of the Markdown editor of a note"))
        setAccessibilityRole(.textArea)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        onDraw()
    }

    // MARK: Services

    /// No text goes to a Service (including ones that send it off the Mac): a Service asks for a requestor with
    /// the types it wants to send or receive, and none is offered. The editor's own paste and drop go through
    /// the `NSTextView` API instead.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?
    )
        -> Any?
    {
        nil
    }

    // MARK: Pasteboard

    /// The selected text, as the editor shows it (Markdown source).
    var selectedSource: String? {
        let range = selectedRange()
        guard range.length > 0 else { return nil }
        return (string as NSString).substring(with: range)
    }

    override func copy(_ sender: Any?) {
        guard let text = selectedSource else { return }
        copyText(text)
    }

    override func cut(_ sender: Any?) {
        guard isEditable, let text = selectedSource else { return }
        copyText(text)
        let range = selectedRange()
        if shouldChangeText(in: range, replacementString: "") {
            replaceCharacters(in: range, with: "")
            didChangeText()
        }
    }

    /// Other writers of the selection (Services, a drag out): the general pasteboard goes through the port; a drag
    /// pasteboard keeps the system behaviour, which a drag needs.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard pboard.name == NSPasteboard.Name.general else { return super.writeSelection(to: pboard, types: types) }
        guard types.contains(.string), let text = selectedSource else { return false }
        copyText(text)
        return true
    }

    /// Pasted text is inserted as plain text: no formatting, no attachments.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    // MARK: Find pasteboard

    /// "Use Selection for Find" would put the selected text on the find pasteboard, outside the plugin's
    /// pasteboard port (no transient or concealed marker). It is switched off; Find itself still works.
    private static func setsFindString(_ sender: Any?) -> Bool {
        if let item = sender as? NSMenuItem {
            return item.tag == Int(NSFindPanelAction.setFindString.rawValue)
                || item.tag == NSTextFinder.Action.setSearchString.rawValue
        }
        return false
    }

    override func performFindPanelAction(_ sender: Any?) {
        guard !Self.setsFindString(sender) else { return }
        super.performFindPanelAction(sender)
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard !Self.setsFindString(sender) else { return }
        super.performTextFinderAction(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.tag == Int(NSFindPanelAction.setFindString.rawValue),
            item.action == #selector(NSResponder.performTextFinderAction(_:))
                || item.action == #selector(NSTextView.performFindPanelAction(_:))
        {
            return false
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Shortcuts

    /// ⇧⌘M: the character "m", or, on a layout whose letters are not Latin (Cyrillic, Greek, ...), the physical
    /// key where the ANSI M sits (key code 46), so the shortcut does not depend on the layout's characters.
    static func isCommentKey(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if chars == "m" { return true }
        let isLatinLetter = chars.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic }
        return event.keyCode == 46 && !isLatinLetter
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isEditable, flags == .command, let key = event.charactersIgnoringModifiers {
            switch key {
            case "b":
                formatShortcut(.bold)
                return true
            case "i":
                formatShortcut(.italic)
                return true
            default: break
            }
        }
        if isEditable, flags == [.command, .shift], Self.isCommentKey(event), let commentShortcut {
            commentShortcut()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
