import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

/// Manual notes (spec step 4.4): ⌘N, the explorer's "+", `notes:<uuid>` keys, the title and the editor.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ManualNoteTests {
    private func model(_ r: ReconRig, writing: Bool = true) -> NotesWorkspaceModel {
        var environment = NotesWorkspaceModel.Environment(library: r.library, pasteboard: RecordingPasteboard())
        environment.registry = r.registry
        let store = r.store
        environment.overlayHeads = { item in (try? NoteOverlayContent.heads(for: item, in: store)) ?? [] }
        if writing {
            environment.installWriting(
                store: { store }, registry: r.registry, settings: r.rig.harness.settings, clock: r.rig.clock)
        }
        return NotesWorkspaceModel(environment: environment)
    }

    private func edit(_ text: String) -> NoteEditorEdit {
        NoteEditorEdit(text: text, range: 0..<text.utf16.count, changeInLength: text.utf16.count)
    }

    // MARK: Creating

    @Test func aNewNoteIsListedOpenedAndReadyToType() async throws {
        let r = try ReconRig()
        let model = model(r)
        await model.refresh()
        #expect(model.canCreateNote)
        await model.newNote()
        let row = try #require(model.rows.first)
        #expect(row.summary.kind == .manual)
        #expect(row.id.key.rawValue.hasPrefix("notes:"))
        #expect(model.currentID == row.id)
        let document = try #require(model.currentDocument)
        #expect(document.phase == .loaded && document.isManual)
        #expect(document.layers.map(\.id) == ["body"])
        let session = try #require(document.session)
        #expect(session.isEditable)
        // Typing goes to the writer and a flush writes a `human` revision on the manual document.
        session.handle(edit("My first note"))
        await session.flush()
        let docID = try #require(try r.store.liveDocument(key: row.id.key, layer: "body")?.id)
        let head = try r.rig.head(docID)
        #expect(head.body == "My first note" && head.author == "human")
        #expect(try r.store.revisions(of: docID).first?.body == "")
    }

    @Test func everyNoteGetsItsOwnKeyInTheReservedNamespace() async throws {
        let r = try ReconRig()
        let model = model(r)
        await model.refresh()
        await model.newNote()
        await model.newNote()
        let keys = model.rows.map(\.id.key)
        #expect(keys.count == 2 && Set(keys).count == 2)
        for key in keys {
            #expect(key.pluginID == "notes")
            let id = String(key.rawValue.dropFirst("notes:".count))
            #expect(UUID(uuidString: id) != nil && id == id.lowercased())
        }
        #expect(model.tabs.tabs.count == 2)
    }

    @Test func anExplorerSearchIsClearedSoTheNewRowShows() async throws {
        let r = try ReconRig()
        let model = model(r)
        await model.refresh()
        model.searchText = "zzz"
        await model.runSearch()
        #expect(model.isSearching)
        await model.newNote()
        #expect(!model.isSearching)
        #expect(model.rows.count == 1)
    }

    @Test func withoutWritingNothingIsCreatedAndTheCommandIsOff() async throws {
        let r = try ReconRig()
        let model = model(r, writing: false)
        await model.refresh()
        #expect(!model.canCreateNote)
        await model.newNote()
        #expect(model.rows.isEmpty && model.tabs.tabs.isEmpty)
    }

    @Test func aStoreThatRefusesWritesSaysSoAndOpensNothing() async throws {
        let r = try ReconRig()
        r.rig.harness.settingsStore.setValue(.bool(true), forKey: "plugins.notes.readOnly")
        let model = model(r)
        await model.refresh()
        await model.newNote()
        #expect(model.feedback == .createFailed)
        #expect(model.rows.isEmpty && model.tabs.tabs.isEmpty)
    }

    @Test func theMenuItemIsNewNoteWithCommandNAndFollowsTheStore() async throws {
        let storage = FileManager.default.temporaryDirectory.appending(
            path: "lintel-notes-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: storage) }
        let plugin = NotesPlugin(context: makeContext(storage: storage, keychain: MemoryKeychain()))
        let section = try #require(plugin.workspaceSections.first)
        let item = try #require(section.menuItems.first)
        #expect(String(localized: item.title) == "New Note")
        #expect(item.shortcut == KeyShortcut(key: "n", modifiers: [.command]))
        await plugin.workspace.refresh()
        #expect(item.isEnabled())
        item.run()
        await waitUntil { plugin.workspace.currentDocument?.isEditing == true }
        #expect(plugin.workspace.rows.count == 1)
        // The hidden read-only key turns the command off.
        let settings = MemorySettings()
        PluginSettings(pluginID: "notes", store: settings).set(true, for: NotesSettingsKey.readOnly)
        let locked = NotesPlugin(context: makeContext(storage: storage, settings: settings, keychain: MemoryKeychain()))
        await locked.workspace.refresh()
        #expect(try #require(locked.workspaceSections.first?.menuItems.first).isEnabled() == false)
    }

    @Test func aRouteToAManualKeyOpensItsTabAndTheReservedIDIsNotASource() async throws {
        let r = try ReconRig()
        let model = model(r)
        await model.refresh()
        await model.newNote()
        let key = try #require(model.rows.first?.id.key)
        model.close(.live(key))
        #expect(model.handle(NoteRoute.route(for: key)))
        #expect(model.currentID == .live(key))
        await model.loadContent(.live(key))
        #expect(model.currentDocument?.phase == .loaded)
        // A source that claims `notes` for itself is not a source of Notes (the plugin id is Notes' own).
        #expect(NoteSourceSet.reservedID == NotesStore.manualPluginID)
    }

    // MARK: Titles

    @Test func aTitleIsCleanedStoredListedAndSearchable() async throws {
        let r = try ReconRig()
        let model = model(r)
        await model.refresh()
        await model.newNote()
        let id = try #require(model.currentID)
        #expect(model.title(of: try #require(model.row(for: id))) == "Untitled note")
        await model.setTitle(id, to: "  Plan\u{202E}\nfor\tFriday \u{200B}")
        #expect(model.title(of: try #require(model.row(for: id))) == "Plan for Friday")
        #expect(model.tabs.tabs.first?.title == "Plan for Friday")
        // The index follows the title through the trigger.
        let hits = try r.store.search("friday")
        #expect(hits.map(\.key) == [id.key] && hits.first?.titleMatched == true)
        await model.setTitle(id, to: "   ")
        #expect(model.title(of: try #require(model.row(for: id))) == "Untitled note")
    }

    @Test func aTitleIsOneLineOfAtMostTwoHundredCharacters() {
        #expect(NotesStore.cleanTitle(String(repeating: "a", count: 500))?.count == 200)
        #expect(NotesStore.cleanTitle("a\r\nb") == "a b")
        #expect(NotesStore.cleanTitle("\u{0007}\u{200B}") == nil)
        #expect(NotesStore.cleanTitle(nil) == nil)
    }

    @Test func onlyAManualNoteHasATitleOverride() async throws {
        let r = try ReconRig()
        let doc = try r.rig.seededDocument(r.rig.layer("agent notes"))
        #expect(try r.store.setTitleOverride(key: r.key, title: "mine", now: Date()) == false)
        #expect(try r.store.document(id: doc.id) != nil)
        let model = model(r)
        r.publish([r.rig.layer("agent notes")])
        await model.refresh()
        model.open(.live(r.key))
        await model.setTitle(.live(r.key), to: "mine")
        #expect(model.row(for: .live(r.key))?.summary.title == "t")
    }

    // MARK: The editor

    @Test func leavingTheEditorWritesTheTextAndReadsTheHeadBack() async throws {
        let r = try ReconRig()
        let model = model(r)
        await model.refresh()
        await model.newNote()
        let id = try #require(model.currentID)
        let document = try #require(model.documents[id])
        document.session?.handle(edit("Typed text"))
        model.toggleEditing()
        #expect(!document.isEditing)
        await waitUntil { document.layers.first?.markdown == "Typed text" }
        #expect(document.frozenLayers.isEmpty)
        // The pen opens it again on the head.
        model.toggleEditing()
        #expect(document.isEditing)
    }

    @Test func switchingLayersLeavesTheEditorOfTheFirstOne() async throws {
        let r = try ReconRig()
        let layers = [
            r.rig.layer("agent notes", id: "notes", version: "n1"),
            r.rig.layer("segment", id: "transcript", version: "t1", author: .stt),
        ]
        r.publish(layers)
        let model = model(r)
        await model.refresh()
        model.open(.live(r.key))
        await model.loadContent(.live(r.key))
        model.beginEditing(.live(r.key))
        let document = try #require(model.currentDocument)
        #expect(document.isEditing)
        document.selectLayer("transcript")
        #expect(!document.isEditing)
        model.beginEditing(.live(r.key))
        #expect(document.session?.documentID == .live(r.key, layer: "transcript"))
    }

    @Test func theEditorIsOfferedOnlyWhereTheSpecAllowsIt() async throws {
        let r = try ReconRig()
        let model = model(r)
        await model.refresh()
        // A recorded note: only in the states that allow seeding.
        for (state, allowed) in [
            (NoteState.ready, true), (.partial, true), (.stale, true), (.failed, true), (.needsModel, true),
            (.recording, false), (.processing, false), (.writing(done: 1, of: 2), false),
        ] {
            r.publish([r.rig.layer("text")], state: state)
            let id = NoteItemID.live(r.key)
            model.close(id)
            model.open(id)
            await model.loadContent(id)
            #expect(model.canEdit(try #require(model.documents[id])) == allowed, "\(state)")
        }
        // A layer that already has an overlay stays editable while the source is writing.
        try r.rig.seededDocument(r.rig.layer("text"))
        r.publish([r.rig.layer("text")], state: .writing(done: 1, of: 2))
        model.close(.live(r.key))
        model.open(.live(r.key))
        await model.loadContent(.live(r.key))
        #expect(model.canEdit(try #require(model.documents[.live(r.key)])))
        // Too long: read-only, with Export.
        let long = String(repeating: "x", count: NotesWorkspaceModel.editableLimit + 1)
        r.publish([r.rig.layer(long, id: "transcript", author: .stt)], key: NoteKey(pluginID: "meetings", id: "m2"))
        let big = NoteItemID.live(NoteKey(pluginID: "meetings", id: "m2"))
        model.open(big)
        await model.loadContent(big)
        #expect(!model.canEdit(try #require(model.documents[big])))
        // No store to write to: no pen.
        let plain = self.model(r, writing: false)
        plain.open(.live(r.key))
        await plain.loadContent(.live(r.key))
        #expect(!plain.canEdit(try #require(plain.documents[.live(r.key)])))
    }

    @Test func aDetachedNoteIsNeverEditable() async throws {
        let r = try ReconRig()
        try await r.editedOverlay(r.rig.layer("old", version: "n1"), text: "kept")
        try r.store.detachReportingRows(r.key)
        let model = model(r)
        let item = NoteItemID.detached(r.key, startedAtMs: NoteTime.milliseconds(r.rig.started))
        model.open(item)
        await model.loadContent(item)
        #expect(!model.canEdit(try #require(model.documents[item])))
    }

    @Test func aFailedWriteShowsTheStripAndTryAgainSavesTheKeptText() async throws {
        let r = try ReconRig()
        let model = model(r)
        await model.refresh()
        await model.newNote()
        let document = try #require(model.currentDocument)
        let session = try #require(document.session)
        try r.rig.failNextInsert(body: "doomed")
        session.handle(edit("doomed"))
        await session.flush()
        #expect(session.saveFailed)
        #expect(model.strips.contains { $0.id == "edit.save" })
        try r.rig.clearFault()
        await model.perform("edit.save.retry")
        #expect(!session.saveFailed)
        #expect(!model.strips.contains { $0.id == "edit.save" })
    }

    @Test func aManualNoteNeverTouchesASource() async throws {
        let r = try ReconRig()
        let model = model(r)
        await model.refresh()
        await model.newNote()
        #expect(r.source.contentCalls == 0)
        await model.refresh()
        #expect(r.source.contentCalls == 0)
        #expect(model.currentDocument?.phase == .loaded)
    }
}
