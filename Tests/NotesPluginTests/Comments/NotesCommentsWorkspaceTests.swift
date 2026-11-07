import AppKit
import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

/// Spec steps 5.2 and 5.3: the open note's comments in the workspace model (threads, reply, resolve, filter), the
/// highlights, `plugins.notes.readOnly`, and the count behind "Revise with N comments".
@MainActor
@Suite(.timeLimit(.minutes(1))) struct NotesCommentsWorkspaceTests {
    private let notes = "## Decisions\n\n- Ship onboarding on 12 Nov.\n- Pricing page moves to the next sprint."

    private struct Setup {
        let r: ReconRig
        let model: NotesWorkspaceModel
        let item: NoteItemID
    }

    private func setup(
        canEdit: Bool = true, revise: (@MainActor (ReviseCall) async -> ReviseOutcome)? = nil,
        afterLoad: (@MainActor (Int) async -> Void)? = nil
    ) async throws -> Setup {
        let r = try ReconRig()
        let layers = [r.rig.layer(notes, id: "notes", version: "n1")]
        r.publish(layers)
        var environment = NotesWorkspaceModel.Environment(library: r.library, pasteboard: RecordingPasteboard())
        environment.registry = r.registry
        let store = r.store
        environment.overlayHeads = { item in (try? NoteOverlayContent.heads(for: item, in: store)) ?? [] }
        environment.canEditNotes = canEdit
        environment.installComments(store: { store })
        environment.revise = revise
        if let afterLoad {
            let original = environment.loadComments
            let calls = CommentBox(0)
            environment.loadComments = { item, layer in
                calls.value += 1
                let number = calls.value
                let state = await original(item, layer)
                await afterLoad(number)
                return state
            }
        }
        environment.makeEditingSession = { content, layerID, document in
            NoteEditingSession.make(
                content: content, layerID: layerID, store: store, registry: r.registry, model: document,
                readOnly: !canEdit)
        }
        let model = NotesWorkspaceModel(environment: environment)
        let item = NoteItemID.live(r.key)
        model.open(item)
        await model.loadContent(item)
        return Setup(r: r, model: model, item: item)
    }

    private func comment(_ s: Setup, _ quote: String, _ body: String) async throws -> Bool {
        s.model.beginEditing(s.item)
        let range = (notes as NSString).range(of: quote)
        return await s.model.addComment(body: body, selection: range, buffer: notes)
    }

    @Test func aCommentSeedsTheOverlayAndShowsInTheDocumentWithTheOpenCount() async throws {
        let s = try await setup()
        let document = try #require(s.model.documents[s.item])
        #expect(document.comments == .none)
        #expect(document.openCommentCount == 0)
        #expect(try await comment(s, "next sprint", "Which sprint?"))
        #expect(document.openCommentCount == 1)
        #expect(document.commentThreads.first?.root.body == "Which sprint?")
        #expect(document.selectedThreadID == document.commentThreads.first?.id)
        #expect(s.model.inspectorTab == .comments)
        #expect(s.model.reviseCount == 1)
        // The highlight is where the quote is in the head.
        let highlight = try #require(document.highlights.first)
        #expect((notes as NSString).substring(with: highlight.range) == "next sprint")
        #expect(highlight.isSelected)
    }

    @Test func replyResolveAndReopenMoveTheCountsAndTheFilter() async throws {
        let s = try await setup()
        let document = try #require(s.model.documents[s.item])
        _ = try await comment(s, "Ship", "Date?")
        _ = try await comment(s, "Pricing", "Which page?")
        #expect(document.openCommentCount == 2)
        let first = try #require(document.commentThreads.first)
        #expect(await s.model.reply(to: first, body: "12 Nov"))
        #expect(document.commentThreads.first?.comments.count == 2)
        await s.model.setStatus(.resolved, of: first)
        #expect(document.openCommentCount == 1)
        #expect(document.resolvedThreads.map(\.id) == [first.id])
        #expect(document.shownThreads.map(\.id) != [first.id])
        document.commentFilter = .resolved
        #expect(document.shownThreads.map(\.id) == [first.id])
        // A resolved thread has no highlight.
        #expect(document.highlights.count == 1)
        let resolved = try #require(document.resolvedThreads.first)
        await s.model.setStatus(.open, of: resolved)
        #expect(document.openCommentCount == 2)
    }

    @Test func aThreadWhoseTextWasDeletedIsReportedAsChangedAndHasNoHighlight() async throws {
        let s = try await setup()
        let document = try #require(s.model.documents[s.item])
        _ = try await comment(s, "next sprint", "Which sprint?")
        let thread = try #require(document.commentThreads.first)
        #expect(!document.isTextChanged(thread))
        // The editor's buffer no longer has the quote: the highlight goes, the thread says "text changed".
        document.setEditorText(notes.replacingOccurrences(of: "next sprint", with: "week 46"))
        document.flushResolutions()  // the quotes are searched once typing paused
        #expect(document.isTextChanged(thread))
        #expect(document.highlights.isEmpty)
        // An edit before the quote only moves the highlight.
        document.setEditorText("Intro line.\n\n" + notes)
        document.flushResolutions()
        #expect(!document.isTextChanged(thread))
        let range = try #require(document.highlights.first?.range)
        #expect((("Intro line.\n\n" + notes) as NSString).substring(with: range) == "next sprint")
    }

    @Test func withoutEditingRightsNothingIsWrittenAndTheReasonIsShown() async throws {
        let s = try await setup(canEdit: false)
        let document = try #require(s.model.documents[s.item])
        #expect(!s.model.canWriteComments(document))
        #expect(await s.model.environment.writeComment(.setStatus(docID: 1, threadID: 1, status: .resolved)) != nil)
        #expect(s.model.currentDocument?.session == nil)
    }

    @Test func readOnlyAfterTheFactRefusesTheReplyAndKeepsTheThreadOpen() async throws {
        let s = try await setup()
        let document = try #require(s.model.documents[s.item])
        _ = try await comment(s, "Ship", "Date?")
        s.r.rig.harness.settingsStore.setValue(.bool(true), forKey: "plugins.notes.readOnly")
        let thread = try #require(document.commentThreads.first)
        #expect(await !s.model.reply(to: thread, body: "x"))
        #expect(s.model.feedback == .commentReadOnly)
        await s.model.setStatus(.resolved, of: thread)
        #expect(document.openCommentCount == 1)
        // Reads still work.
        await s.model.refreshComments(s.item)
        #expect(document.commentThreads.count == 1)
    }

    @Test func aDetachedOverlayShowsItsCommentsButTakesNoWrites() async throws {
        let s = try await setup()
        let document = try #require(s.model.documents[s.item])
        _ = try await comment(s, "Ship", "Date?")
        try s.r.store.detachReportingRows(s.r.key)
        let detached = NoteItemID.detached(s.r.key, startedAtMs: NoteTime.milliseconds(s.r.rig.started))
        s.model.open(detached)
        await s.model.loadContent(detached)
        let copy = try #require(s.model.documents[detached])
        #expect(copy.openCommentCount == 1)
        #expect(!s.model.canWriteComments(copy))
        _ = document
    }

    // MARK: Review fixes

    @Test func typingSearchesNoQuoteUntilItPausesAndReadsNeverSearch() async throws {
        let s = try await setup()
        let document = try #require(s.model.documents[s.item])
        _ = try await comment(s, "Ship", "a")
        _ = try await comment(s, "Pricing", "b")
        _ = try await comment(s, "next sprint", "c")
        let searches = CommentBox(0)
        document.resolveAnchor = { anchor, text in
            searches.value += 1
            return AnchorResolver.resolve(anchor, in: text)
        }
        document.resolveDelay = .seconds(3600)  // the pause never ends inside the test
        document.refreshResolutions()
        #expect(searches.value == 3)  // one search per open thread
        var typed = notes
        for index in 0..<50 {
            typed += "x"
            let at = (typed as NSString).length - 1
            document.setEditorText(
                typed, edit: NoteEditorEdit(text: typed, range: at..<(at + 1), changeInLength: 1))
            _ = index
        }
        for _ in 0..<20 {  // redraws: highlights and labels come from the cache
            _ = document.highlights
            _ = document.commentThreads.map(document.isTextChanged)
        }
        #expect(searches.value == 3)  // 50 keystrokes and 20 redraws searched nothing
        document.flushResolutions()
        #expect(searches.value == 6)  // once for the pause
        #expect(document.highlights.count == 3)
        document.flushResolutions()
        #expect(searches.value == 9)
    }

    @Test func anEditBeforeAQuoteMovesItsHighlightWithoutSearching() async throws {
        let s = try await setup()
        let document = try #require(s.model.documents[s.item])
        _ = try await comment(s, "next sprint", "c")
        document.resolveDelay = .seconds(3600)
        let typed = "Intro. " + notes
        document.setEditorText(typed, edit: NoteEditorEdit(text: typed, range: 0..<7, changeInLength: 7))
        let range = try #require(document.highlights.first?.range)
        #expect((typed as NSString).substring(with: range) == "next sprint")
    }

    @Test func theReviseCountLeavesOutThreadsTheRunWouldSkip() async throws {
        let s = try await setup()
        let document = try #require(s.model.documents[s.item])
        _ = try await comment(s, "Ship", "a")
        _ = try await comment(s, "next sprint", "b")
        #expect(s.model.reviseCount == 2)
        #expect(document.openCommentCount == 2)
        // "next sprint" is deleted: that thread is "Text changed" and a run would skip it.
        document.setEditorText(notes.replacingOccurrences(of: "next sprint", with: "week 46"))
        document.flushResolutions()
        #expect(s.model.reviseCount == 1)
        #expect(document.openCommentCount == 2)  // the tab still counts every open thread
    }

    @Test func aSlowCommentReadNeverOverwritesANewerOne() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let armed = CommentBox(false)
        let s = try await setup(afterLoad: { _ in
            guard armed.value else { return }  // only the read started after arming is slow
            armed.value = false
            entered.continuation.yield()
            for await _ in release.stream { return }
        })
        let document = try #require(s.model.documents[s.item])
        _ = try await comment(s, "Ship", "first")
        #expect(document.commentThreads.count == 1)
        armed.value = true
        let slow = Task { await s.model.refreshComments(s.item) }
        for await _ in entered.stream { break }
        // While it waits, a second thread is written and read.
        let doc = try #require(try s.r.store.liveDocument(key: s.r.key, layer: "notes"))
        let head = try #require(try s.r.store.headRevision(of: doc.id))
        let range = (notes as NSString).range(of: "Pricing")
        _ = try s.r.store.addThread(
            docID: doc.id, author: "human", body: "second",
            anchor: try #require(CommentAnchors.make(in: head.body, range: range)),
            anchorRevisionID: head.id, now: Date())
        await s.model.refreshComments(s.item)
        #expect(document.commentThreads.count == 2)
        release.continuation.yield()
        await slow.value
        #expect(document.commentThreads.count == 2)  // the stale snapshot (1 thread) was dropped
    }

    // MARK: Revise with N comments (step 5.3)

    @Test func theReviseButtonCountsOpenThreadsAndIsOffUntilTheAgentIsWired() async throws {
        let s = try await setup()
        _ = try await comment(s, "Ship", "Date?")
        #expect(s.model.reviseCount == 1)
        #expect(!s.model.canRevise)  // step 6.2 wires `revise`
        await s.model.revise()  // a no-op without the agent
    }

    @Test func theReviseButtonRunsTheAgentWithTheNoteOnceWired() async throws {
        let ran = CommentBox<[NoteItemID]>([])
        let s = try await setup(revise: { call in
            ran.value.append(call.item)
            return .nothingToRevise(skipped: [])
        })
        #expect(!s.model.canRevise)  // nothing open yet
        _ = try await comment(s, "Ship", "Date?")
        #expect(s.model.canRevise)
        await s.model.revise()
        #expect(ran.value == [s.item])
        let thread = try #require(s.model.currentDocument?.commentThreads.first)
        await s.model.setStatus(.resolved, of: thread)
        #expect(s.model.reviseCount == 0)
        #expect(!s.model.canRevise)
    }

    @Test func theLabelIsAPluralInBothLanguagesWithTheRightPolishForms() throws {
        struct Catalog: Decodable {
            struct Unit: Decodable { var value: String }
            struct Variant: Decodable { var stringUnit: Unit }
            struct Plural: Decodable { var plural: [String: Variant] }
            struct Localization: Decodable { var variations: Plural? }
            struct Entry: Decodable { var localizations: [String: Localization] }
            var strings: [String: Entry]
        }
        let data = try Data(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appending(
                    path: "Resources/Localizable.xcstrings"))
        let entry = try #require(
            try JSONDecoder().decode(Catalog.self, from: data).strings["Revise with %lld comments"])
        let en = try #require(entry.localizations["en"]?.variations?.plural)
        let pl = try #require(entry.localizations["pl"]?.variations?.plural)
        #expect(en["one"]?.stringUnit.value == "Revise with %lld comment")
        #expect(en["other"]?.stringUnit.value == "Revise with %lld comments")
        // CLDR Polish: one = 1, few = 2-4 (22-24...), many = 0 and 5-21 (...), other = fractions.
        #expect(pl["one"]?.stringUnit.value == "Popraw według %lld komentarza")
        #expect(pl["few"]?.stringUnit.value == "Popraw według %lld komentarzy")
        #expect(pl["many"]?.stringUnit.value == "Popraw według %lld komentarzy")
        #expect(pl["other"]?.stringUnit.value == "Popraw według %lld komentarza")
        #expect(Set(pl.keys) == ["one", "few", "many", "other"])
    }

    // MARK: Accessibility

    @Test func everyThreadIsAnnouncedWithItsQuote() throws {
        func record(_ quote: String, status: CommentStatus) -> CommentRecord {
            CommentRecord(
                id: 1, docID: 1, threadID: 1, author: "human", createdAt: Date(timeIntervalSince1970: 1), body: "b",
                anchorRevisionID: 1,
                anchor: CommentAnchor(start: 0, end: 1, blockHash: "h", quote: quote, prefix: "", suffix: ""),
                status: status, resolvedAt: nil)
        }
        let open = CommentThread(threadID: 1, comments: [record("next sprint", status: .open)])
        #expect(open.spokenTitle(textChanged: false) == "Comment on “next sprint”")
        #expect(open.spokenTitle(textChanged: true).hasPrefix("Comment on “next sprint”. "))
        let resolved = CommentThread(threadID: 1, comments: [record("Marek", status: .resolved)])
        #expect(resolved.spokenTitle(textChanged: false) == "Resolved comment on “Marek”")
        let long = CommentThread(threadID: 1, comments: [record(String(repeating: "word ", count: 40), status: .open)])
        #expect(long.displayQuote.count == CommentThread.quoteDisplayLimit + 1)
        #expect(long.displayQuote.hasSuffix("…"))
        let multiline = CommentThread(threadID: 1, comments: [record("one\n\ntwo", status: .open)])
        #expect(multiline.displayQuote == "one two")
        #expect(CommentThread.spokenMeta(author: "human", when: "today 14:58") == "You, today 14:58")
        #expect(CommentThread.spokenMeta(author: "agent", when: "today 14:57") == "AI, today 14:57")
    }

    // MARK: The editor

    @Test func highlightsAreRenderingAttributesAndNeverChangeTheText() throws {
        let controller = NoteEditorController(pasteboard: RecordingPasteboard())
        controller.setText(notes)
        let before = controller.text
        let range = (notes as NSString).range(of: "next sprint")
        controller.setHighlights([CommentHighlight(threadID: 1, range: range, isSelected: false)], pending: nil)
        controller.setHighlights(
            [CommentHighlight(threadID: 1, range: NSRange(location: 9000, length: 5), isSelected: true)],
            pending: range)
        controller.setHighlights([], pending: nil)
        #expect(controller.text == before)
        let storage = try #require(controller.textView.textStorage)
        var painted = false
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value != nil { painted = true }
        }
        #expect(!painted)  // the Markdown storage carries no highlight, so undo and the styler never see one
    }

    @Test func theCommentShortcutIsShiftCommandMAndNotOptionCommandM() throws {
        let controller = NoteEditorController(pasteboard: RecordingPasteboard())
        controller.setText(notes)
        var count = 0
        controller.textView.commentShortcut = { count += 1 }
        func event(_ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: "m", charactersIgnoringModifiers: "m", isARepeat: false, keyCode: 46)
        }
        _ = try controller.textView.performKeyEquivalent(with: #require(event([.command, .shift])))
        #expect(count == 1)
        _ = try controller.textView.performKeyEquivalent(with: #require(event([.command, .option])))
        #expect(count == 1)  // ⌥⌘M is Window → Minimize All
        controller.isReadOnly = true
        _ = try controller.textView.performKeyEquivalent(with: #require(event([.command, .shift])))
        #expect(count == 1)  // read-only: no comment
    }

    @Test func theShortcutFollowsThePhysicalKeyOnANonLatinLayout() throws {
        func event(_ chars: String, keyCode: UInt16) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
                    context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                    keyCode: keyCode))
        }
        #expect(NoteEditorTextView.isCommentKey(try event("m", keyCode: 46)))
        #expect(NoteEditorTextView.isCommentKey(try event("ь", keyCode: 46)))  // Russian: the same key
        #expect(!NoteEditorTextView.isCommentKey(try event("n", keyCode: 45)))
        #expect(!NoteEditorTextView.isCommentKey(try event("x", keyCode: 46)))  // a Latin layout with x there
    }

    @Test func aStaleLongSelectionThatReachesTheServiceShowsTheRightStrip() async throws {
        let s = try await setup()
        s.model.beginEditing(s.item)
        let long = String(repeating: "word ", count: 500)
        let wrote = await s.model.addComment(
            body: "x", selection: NSRange(location: 0, length: CommentAnchors.maxQuoteLength + 1), buffer: long)
        #expect(!wrote)
        #expect(s.model.feedback == .commentSelectionTooLong)
        let none = await s.model.addComment(body: "x", selection: NSRange(location: 2, length: 0), buffer: notes)
        #expect(!none)
        #expect(s.model.feedback == .commentSelectionInvalid)
    }
}

final class CommentBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
