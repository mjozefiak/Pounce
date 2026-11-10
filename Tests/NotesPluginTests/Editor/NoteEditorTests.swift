import AppKit
import LintelKit
import LintelUI
import Testing

@testable import NotesPlugin

/// A deterministic generator (SplitMix64) so the random edits of a test repeat exactly.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
private func makeController(
    text: String = "", readOnly: Bool = false, pasteboard: RecordingPasteboard = RecordingPasteboard()
) -> NoteEditorController {
    let controller = NoteEditorController(pasteboard: pasteboard, isReadOnly: readOnly)
    controller.setText(text)
    return controller
}

/// Every character's attributes, as comparable text.
@MainActor
private func fingerprint(_ storage: NSTextStorage) -> [String] {
    (0..<storage.length).map { index in
        let attributes = storage.attributes(at: index, effectiveRange: nil)
        let font = attributes[.font] as? NSFont
        let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
        let strike = (attributes[.strikethroughStyle] as? Int) ?? 0
        let background = attributes[.backgroundColor] != nil
        return
            "\(font?.fontName ?? "-") \(font?.pointSize ?? 0) \(attributes[.foregroundColor] as? NSColor ?? .clear) \(strike) \(background) \(paragraph?.lineHeightMultiple ?? 0)"
    }
}

@Suite("Note editor", .serialized)
@MainActor
struct NoteEditorTests {
    // MARK: Configuration

    @Test("the text view is TextKit 2 with Writing Tools, Services and the automatic substitutions off")
    func configuration() {
        let view = makeController().textView
        #expect(view.textLayoutManager != nil)
        #expect(view.textContentStorage != nil)
        #expect(view.writingToolsBehavior == .none)
        #expect(view.allowsUndo)
        #expect(view.isRichText == false)
        #expect(view.importsGraphics == false)
        #expect(view.isAutomaticQuoteSubstitutionEnabled == false)
        #expect(view.isAutomaticDashSubstitutionEnabled == false)
        #expect(view.isAutomaticTextReplacementEnabled == false)
        #expect(view.isAutomaticSpellingCorrectionEnabled == false)
        #expect(view.isAutomaticLinkDetectionEnabled == false)
        #expect(view.isAutomaticDataDetectionEnabled == false)
        // Spelling and grammar stay on, on this Mac.
        #expect(view.isContinuousSpellCheckingEnabled)
        #expect(view.isEditable)
        #expect(view.validRequestor(forSendType: .string, returnType: nil) == nil)
        #expect(view.validRequestor(forSendType: nil, returnType: .string) == nil)
        #expect(view.readablePasteboardTypes == [.string])
    }

    @Test("a read-only editor selects and copies but never changes, and format actions do nothing")
    func readOnly() {
        let pasteboard = RecordingPasteboard()
        let controller = makeController(text: "hello", readOnly: true, pasteboard: pasteboard)
        #expect(controller.isReadOnly)
        #expect(controller.textView.isEditable == false)
        #expect(controller.textView.isSelectable)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(controller.perform(.bold) == false)
        #expect(controller.text == "hello")
        controller.textView.copy(nil)
        #expect(pasteboard.writes.count == 1)
        controller.textView.cut(nil)
        #expect(controller.text == "hello")
        controller.isReadOnly = false
        #expect(controller.perform(.bold))
        #expect(controller.text == "**hello**")
    }

    // MARK: Pasteboard

    @Test("copy and cut write the selection through the port with both markers, for this Mac only")
    func copyMarkers() throws {
        let pasteboard = RecordingPasteboard()
        let controller = makeController(text: "# Secret plan\nbody", pasteboard: pasteboard)
        let general = NSPasteboard.general.changeCount
        controller.textView.setSelectedRange(NSRange(location: 2, length: 11))
        controller.textView.copy(nil)
        var write = try #require(pasteboard.writes.last)
        #expect(write.options == [.currentHostOnly])
        var item = try #require(write.items.first)
        #expect(item.data(for: PasteboardRepresentation.plainTextType) == Data("Secret plan".utf8))
        #expect(item.types.contains(PasteboardRepresentation.transientMarkerType))
        #expect(item.types.contains(PasteboardRepresentation.concealedMarkerType))
        controller.textView.cut(nil)
        write = try #require(pasteboard.writes.last)
        item = try #require(write.items.first)
        #expect(pasteboard.writes.count == 2)
        #expect(item.types.contains(PasteboardRepresentation.concealedMarkerType))
        #expect(controller.text == "# \nbody")
        #expect(NSPasteboard.general.changeCount == general, "nothing reached the general pasteboard directly")
    }

    @Test("writeSelection to the general pasteboard goes through the port; a drag pasteboard keeps the default")
    func writeSelection() throws {
        let pasteboard = RecordingPasteboard()
        let controller = makeController(text: "abc", pasteboard: pasteboard)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 3))
        #expect(controller.textView.writeSelection(to: .general, types: [.string]))
        #expect(pasteboard.writes.count == 1)
        #expect(controller.textView.writeSelection(to: .general, types: [.rtf]) == false)
        #expect(pasteboard.writes.count == 1)
        let drag = NSPasteboard(name: NSPasteboard.Name("com.lintelapp.tests.notes.\(UUID().uuidString)"))
        defer { drag.releaseGlobally() }
        _ = controller.textView.writeSelection(to: drag, types: [.string])
        #expect(pasteboard.writes.count == 1)
    }

    @Test("nothing is written when nothing is selected")
    func emptyCopy() {
        let pasteboard = RecordingPasteboard()
        let controller = makeController(text: "abc", pasteboard: pasteboard)
        controller.textView.setSelectedRange(NSRange(location: 1, length: 0))
        controller.textView.copy(nil)
        #expect(pasteboard.writes.isEmpty)
    }

    // MARK: Edits

    @Test("typing reports the text and what changed; setText reports nothing and clears undo")
    func reporting() {
        let controller = makeController(text: "ab")
        var edits: [NoteEditorEdit] = []
        controller.onEdit = { edits.append($0) }
        controller.setText("hello")
        #expect(edits.isEmpty)
        let view = controller.textView
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        #expect(edits == [NoteEditorEdit(text: "hello!", range: 5..<6, changeInLength: 1)])
        view.setSelectedRange(NSRange(location: 0, length: 1))
        view.insertText("", replacementRange: NSRange(location: 0, length: 1))
        #expect(edits.last == NoteEditorEdit(text: "ello!", range: 0..<0, changeInLength: -1))
    }

    @Test("a format action is one edit with one undo step, and the selection follows")
    func formatAndUndo() throws {
        let controller = makeController(text: "say hello now")
        // A window that is never ordered in gives the text view the window's undo manager, the one the Edit
        // menu's Undo reaches through the responder chain.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = controller.textView
        var edits = 0
        controller.onEdit = { _ in edits += 1 }
        controller.textView.setSelectedRange(NSRange(location: 4, length: 5))
        #expect(controller.perform(.bold))
        #expect(controller.text == "say **hello** now")
        #expect(edits == 1)
        #expect(controller.textView.selectedRange() == NSRange(location: 6, length: 5))
        // Undo is the text view's own manager, the one the Edit menu's Undo reaches through the responder chain.
        let manager = try #require(controller.textView.undoManager)
        #expect(manager.canUndo)
        manager.undo()
        #expect(controller.text == "say hello now")
        #expect(manager.canRedo)
        manager.redo()
        #expect(controller.text == "say **hello** now")
    }

    // MARK: Styling

    @Test("the text storage is the Markdown source: markers stay, styling only sets attributes")
    func sourceIsStored() throws {
        let text = "# Title\n\nsome **bold** and `code`\n\n- [ ] task"
        let controller = makeController(text: text)
        let storage = try #require(controller.textView.textStorage)
        #expect(storage.string == text)
        let heading = storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        let body = storage.attribute(.font, at: 12, effectiveRange: nil) as? NSFont
        #expect((heading?.pointSize ?? 0) > (body?.pointSize ?? 0))
        let boldRun = storage.attribute(.font, at: 21, effectiveRange: nil) as? NSFont
        #expect(boldRun?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        // No `link` attribute is ever set.
        var links = 0
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value != nil { links += 1 }
        }
        #expect(links == 0)
    }

    @Test("a block-local restyle after random edits equals a full restyle of the same text")
    func blockLocalEqualsFull() throws {
        let pieces = [
            "a", "b ", "**", "*", "`", "~~", "\n", "\n\n", "# ", "- ", "- [ ] ", "> ", "```\n", "```", "|", " | ",
            "[x](y)",
            "é", "\n---\n", "_", "ł",
        ]
        var rng = SeededGenerator(state: 0xC0FFEE)
        let seed =
            "# Title\n\nPara with **bold** and *it*.\n\n```\ncode\n\nmore\n```\n\n- one\n- two\n\n| a | b |\n| --- | --- |\n| 1 | 2 |"
        let controller = makeController(text: seed)
        let storage = try #require(controller.textView.textStorage)
        let view = controller.textView
        var restyledSomething = false
        for step in 0..<400 {
            let length = storage.length
            let location = Int.random(in: 0...length, using: &rng)
            let removed = Int.random(in: 0...min(3, length - location), using: &rng)
            let insert = Int.random(in: 0..<3, using: &rng) == 0 ? "" : pieces.randomElement(using: &rng) ?? "a"
            let range = NSRange(location: location, length: removed)
            if view.shouldChangeText(in: range, replacementString: insert) {
                view.replaceCharacters(in: range, with: insert)
                view.didChangeText()
            }
            let report = controller.styler.lastReport
            if report.restyledBlocks < report.totalBlocks { restyledSomething = true }
            // A fresh styler over a copy of the text is the reference.
            let reference = makeController(text: storage.string)
            let expected = try #require(reference.textView.textStorage)
            #expect(fingerprint(storage) == fingerprint(expected), "step \(step): \(storage.string.debugDescription)")
            #expect(controller.styler.segments == reference.styler.segments, "step \(step)")
        }
        #expect(restyledSomething, "most edits must restyle fewer blocks than the document has")
    }

    @Test("typing in one paragraph restyles that block only")
    func onlyTheEditedBlock() throws {
        let blocks = (0..<200).map { "Paragraph \($0) with **bold** text" }
        let controller = makeController(text: blocks.joined(separator: "\n\n"))
        let view = controller.textView
        let storage = try #require(view.textStorage)
        let target = (storage.string as NSString).range(of: "Paragraph 100 with")
        view.setSelectedRange(NSRange(location: target.location + 4, length: 0))
        view.insertText("x", replacementRange: view.selectedRange())
        #expect(controller.styler.lastReport.restyledBlocks == 1)
        #expect(controller.styler.lastReport.restyledGaps == 0)
        #expect(controller.styler.lastReport.totalBlocks == 200)
        // Opening a fence restyles what the fence swallows (the cascade), still equal to a full pass.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("```\n", replacementRange: NSRange(location: 0, length: 0))
        let reference = makeController(text: storage.string)
        #expect(fingerprint(storage) == fingerprint(try #require(reference.textView.textStorage)))
    }

    @Test("a text size change restyles in full to the new size")
    func textSize() throws {
        let controller = makeController(text: "plain")
        let storage = try #require(controller.textView.textStorage)
        let before = (storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        controller.setTextSize(.extraLarge)
        let after = (storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        #expect(abs(after / before - TextSize.extraLarge.scale) < 0.01)
    }

    @Test("a 60 000 character document opens and a typed character restyles one block")
    func large() throws {
        let blocks = (0..<1_500).map { "Block \($0) with **bold**, *italic* and `code` words" }
        let controller = makeController(text: blocks.joined(separator: "\n\n"))
        let view = controller.textView
        view.setSelectedRange(NSRange(location: 30_000, length: 0))
        view.insertText("z", replacementRange: view.selectedRange())
        #expect(controller.styler.lastReport.restyledBlocks == 1)
    }
}
