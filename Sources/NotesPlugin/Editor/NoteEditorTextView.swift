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

    // MARK: Shortcuts

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
        return super.performKeyEquivalent(with: event)
    }
}
