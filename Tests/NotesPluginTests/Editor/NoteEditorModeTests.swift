import AppKit
import LintelUI
import Testing

@testable import NotesPlugin

@MainActor
private func controller(_ text: String, readOnly: Bool = false) -> NoteEditorController {
    let controller = NoteEditorController(pasteboard: RecordingPasteboard(), isReadOnly: readOnly)
    controller.setText(text)
    return controller
}

@MainActor
private func fonts(_ storage: NSTextStorage) -> Set<String> {
    Set(
        (0..<storage.length).compactMap { (storage.attribute(.font, at: $0, effectiveRange: nil) as? NSFont)?.fontName }
    )
}

@MainActor
private func fingerprint(_ storage: NSTextStorage) -> [String] {
    (0..<storage.length).map { index in
        let attributes = storage.attributes(at: index, effectiveRange: nil)
        let font = attributes[.font] as? NSFont
        return "\(font?.fontName ?? "-") \(font?.pointSize ?? 0) \(attributes[.foregroundColor] as? NSColor ?? .clear)"
    }
}

@Suite("Note editor: Formatted and Raw", .serialized)
@MainActor
struct NoteEditorModeTests {
    private let source = "# Title\n\nSome **bold** and `code`.\n\n- item\n> quote"

    @Test("Raw is plain monospaced text: no heading size, no markers colour, no code well")
    func rawIsPlain() throws {
        let editor = controller(source)
        let storage = try #require(editor.textView.textStorage)
        editor.setMode(.raw)
        let attributes = (0..<storage.length).map { storage.attributes(at: $0, effectiveRange: nil) }
        #expect(Set(attributes.compactMap { ($0[.font] as? NSFont)?.pointSize }).count == 1)
        #expect(
            attributes.allSatisfy { ($0[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true }
        )
        #expect(attributes.allSatisfy { $0[.backgroundColor] == nil && $0[.strikethroughStyle] == nil })
        #expect(Set(attributes.compactMap { $0[.foregroundColor] as? NSColor }).count == 1)
    }

    @Test("switching never changes the text, the selection or reports an edit, and back restores the styling")
    func switchingKeepsEverything() throws {
        let editor = controller(source)
        let storage = try #require(editor.textView.textStorage)
        let before = fingerprint(storage)
        var edits = 0
        editor.onEdit = { _ in edits += 1 }
        editor.textView.setSelectedRange(NSRange(location: 10, length: 6))
        editor.setMode(.raw)
        #expect(editor.text == source)
        #expect(editor.textView.selectedRange() == NSRange(location: 10, length: 6))
        editor.setMode(.formatted)
        #expect(editor.text == source)
        #expect(editor.textView.selectedRange() == NSRange(location: 10, length: 6))
        #expect(fingerprint(storage) == before)
        #expect(edits == 0)
        #expect(editor.mode == .formatted)
    }

    @Test("both modes edit one buffer: typing in Raw reports the same text and Formatted styles it afterwards")
    func sameBuffer() throws {
        let editor = controller("hello")
        let storage = try #require(editor.textView.textStorage)
        var texts: [String] = []
        editor.onEdit = { texts.append($0.text) }
        editor.setMode(.raw)
        editor.textView.insertText("# ", replacementRange: NSRange(location: 0, length: 0))
        #expect(texts == ["# hello"])
        #expect(fonts(storage).count == 1)
        editor.setMode(.formatted)
        let sizes = Set(
            (0..<storage.length).compactMap {
                (storage.attribute(.font, at: $0, effectiveRange: nil) as? NSFont)?.pointSize
            })
        let plain = controller("hello")
        let body = plain.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect((sizes.max() ?? 0) > (body?.pointSize ?? .infinity), "the heading is larger than the body in Formatted")
        #expect(editor.text == "# hello")
        #expect(texts == ["# hello"], "switching adds no edit")
    }

    @Test("undo history survives a switch")
    func undoSurvives() throws {
        let editor = controller("say hello")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = editor.textView
        editor.textView.insertText("!", replacementRange: NSRange(location: 9, length: 0))
        #expect(editor.text == "say hello!")
        editor.setMode(.raw)
        editor.setMode(.formatted)
        editor.setMode(.raw)
        let manager = try #require(editor.textView.undoManager)
        #expect(manager.canUndo)
        manager.undo()
        #expect(editor.text == "say hello")
    }

    @Test("a read-only editor switches too, and stays read-only")
    func readOnly() {
        let editor = controller(source, readOnly: true)
        editor.setMode(.raw)
        #expect(editor.mode == .raw)
        #expect(editor.isReadOnly)
        #expect(editor.text == source)
    }

    @Test("format actions do nothing in Raw: the user types the markers")
    func noFormatActionsInRaw() {
        let editor = controller("word")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 4))
        editor.setMode(.raw)
        #expect(!editor.perform(.bold))
        #expect(editor.text == "word")
        editor.setMode(.formatted)
        #expect(editor.perform(.bold))
    }

    @Test("a new text size keeps the mode")
    func textSizeKeepsMode() {
        let editor = controller(source)
        editor.setMode(.raw)
        editor.setTextSize(.extraLarge)
        #expect(editor.mode == .raw)
    }

    @Test("the policy: Raw has no author bars or format buttons, Formatted follows the preference")
    func policy() {
        #expect(!NoteEditorMode.raw.showsAuthorBars(preference: true))
        #expect(NoteEditorMode.formatted.showsAuthorBars(preference: true))
        #expect(!NoteEditorMode.formatted.showsAuthorBars(preference: false))
        #expect(!NoteEditorMode.raw.offersFormatting && NoteEditorMode.formatted.offersFormatting)
        #expect(NoteEditorMode.formatted.toggled == .raw && NoteEditorMode.raw.toggled == .formatted)
        #expect(NoteEditorMode.qa("raw") == .raw)
        #expect(NoteEditorMode.qa(nil) == .formatted)
        #expect(NoteEditorMode.qa("on") == .formatted)
    }

    @Test("with comment highlights off or on, switching leaves the text and highlights call harmless")
    func highlightsGraceful() {
        let editor = controller(source)
        editor.setHighlights([])
        editor.setMode(.raw)
        editor.setHighlights([], pending: nil)
        #expect(editor.text == source)
    }
}
