import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

@MainActor
@Suite(.timeLimit(.minutes(1))) struct NotesEditingWiringTests {
    private func model(_ r: ReconRig) -> NotesWorkspaceModel {
        var environment = NotesWorkspaceModel.Environment(library: r.library, pasteboard: RecordingPasteboard())
        environment.registry = r.registry
        let store = r.store
        environment.overlayHeads = { item in (try? NoteOverlayContent.heads(for: item, in: store)) ?? [] }
        let model = NotesWorkspaceModel(environment: environment)
        r.registry.onRekey = { [weak model] key, started in model?.rekeyDetached(key: key, startedAtMs: started) }
        return model
    }

    // MARK: Tabs

    @Test func aDetachReKeysTheOpenTabAndARouteToTheNewRowOpensASecondTab() async throws {
        let r = try ReconRig()
        let layers = [
            r.rig.layer("agent notes", id: "notes", version: "n1"),
            r.rig.layer("segment", id: "transcript", version: "t1", author: .stt),
        ]
        let doc = try await r.editedOverlay(layers[0], text: "my notes")
        r.publish(layers)
        let model = model(r)
        model.open(.live(r.key))
        await model.loadContent(.live(r.key))
        let started = NoteTime.milliseconds(r.rig.started)
        let detached = NoteItemID.detached(r.key, startedAtMs: started)
        // Reconciliation on open reads the same note; the overlay head is what the document shows.
        #expect(model.documents[.live(r.key)]?.layers.first { $0.id == "notes" }?.markdown == "my notes")
        r.source.existing = []
        await r.reconciler.sweep()
        #expect(model.tabs.contains(detached))
        #expect(!model.tabs.contains(.live(r.key)))
        #expect(model.currentID == detached)
        // The recreated note's row 1 has the same key: another identity, another tab.
        model.open(.live(r.key))
        #expect(model.tabs.tabs.count == 2)
        #expect(model.currentID == .live(r.key))
        // The detached tab shows only its overlaid layers, never the source's text for a layer without one.
        await waitUntil { model.documents[detached]?.phase == .loaded }
        let shown = try #require(model.documents[detached])
        #expect(shown.layers.map(\.id) == ["notes"])
        #expect(shown.layers.first?.markdown == "my notes")
        _ = doc
    }

    @Test func aDetachedTabNeverReadsTheSource() async throws {
        let r = try ReconRig()
        let doc = try await r.editedOverlay(r.rig.layer("old", version: "n1"), text: "kept")
        try r.store.detachReportingRows(r.key)
        let model = model(r)
        let item = NoteItemID.detached(r.key, startedAtMs: NoteTime.milliseconds(r.rig.started))
        r.publish([r.rig.layer("SOURCE TEXT", version: "n9")])
        model.open(item)
        await model.loadContent(item)
        #expect(r.source.contentCalls == 0)
        #expect(model.documents[item]?.layers.first?.markdown == "kept")
        _ = doc
    }

    @Test func theTabSetReKeysInPlaceAndRefusesADuplicate() {
        var tabs = NoteTabSet()
        let key = NoteKey(pluginID: "meetings", id: "m1")
        tabs.open(NoteTab(id: .live(key), kind: .meeting, title: "One"))
        tabs.open(NoteTab(id: .live(NoteKey(pluginID: "meetings", id: "m2")), kind: .meeting, title: "Two"))
        tabs.select(.live(key))
        let moved = tabs.rekey(from: .live(key), to: .detached(key, startedAtMs: 5))
        #expect(moved)
        #expect(tabs.tabs.map(\.title) == ["One", "Two"])
        #expect(tabs.current == .detached(key, startedAtMs: 5))
        let again = tabs.rekey(from: .live(key), to: .detached(key, startedAtMs: 5))
        #expect(!again)
    }

    // MARK: Registry and closing

    @Test func closingATabWritesTheBufferAndForgetsTheDocument() async throws {
        let r = try ReconRig()
        let doc = try r.rig.seededDocument(r.rig.layer("agent"))
        let writer = r.registry.writer(for: .live(r.key, layer: "notes"), item: .live(r.key)) {
            r.rig.writer(.existing(docID: doc.id))
        }
        writer.submit("typed")
        await r.registry.release(item: .live(r.key))
        #expect(try r.rig.head(doc.id).body == "typed")
        #expect(r.registry.documentIDs.isEmpty)
    }

    // MARK: The editing session

    @Test func theSessionRefusesToSeedWhileTheSourceIsStillWorking() throws {
        let r = try ReconRig()
        for state in [NoteState.recording, .processing, .writing(done: 1, of: 2)] {
            let content = r.rig.content(layers: [r.rig.layer("text")], state: state)
            #expect(
                NoteEditingSession.make(
                    content: content, layerID: "notes", store: r.store, registry: r.registry, readOnly: false) == nil)
        }
    }

    @Test func aLayerThatAlreadyHasAnOverlayStaysEditableInAnyState() throws {
        let r = try ReconRig()
        try r.rig.seededDocument(r.rig.layer("text"))
        let content = r.rig.content(layers: [r.rig.layer("text")], state: .writing(done: 1, of: 2))
        let session = NoteEditingSession.make(
            content: content, layerID: "notes", store: r.store, registry: r.registry, readOnly: false)
        #expect(session?.isEditable == true)
    }

    @Test func theReadOnlyKeyBlocksTheSessionAndNothingIsWritten() async throws {
        let r = try ReconRig()
        let content = r.rig.content(layers: [r.rig.layer("text")])
        let session = try #require(
            NoteEditingSession.make(
                content: content, layerID: "notes", store: r.store, registry: r.registry, readOnly: true))
        #expect(!session.isEditable)
        session.handle(NoteEditorEdit(text: "typed", range: 0..<5, changeInLength: 5))
        #expect(!session.writer.hasPendingText)
        #expect(await session.flush() == .nothing)
        #expect(try r.store.liveDocument(key: r.key, layer: "notes") == nil)
    }

    @Test func theEditorReportsEditsToTheWriterAndFreezesTheRenderedLayer() async throws {
        let r = try ReconRig()
        let layer = r.rig.layer("rendered", version: "v1")
        let content = r.rig.content(layers: [layer])
        let document = NoteDocumentModel(id: .live(r.key))
        document.apply(content)
        let session = try #require(
            NoteEditingSession.make(
                content: content, layerID: "notes", store: r.store, registry: r.registry, model: document,
                readOnly: false)
        )
        let controller = NoteEditorController(pasteboard: RecordingPasteboard())
        session.attach(to: controller)
        #expect(!controller.isReadOnly)
        controller.onEdit(NoteEditorEdit(text: "rendered, typed", range: 8..<15, changeInLength: 7))
        // The source changes after the first keystroke: the view keeps the frozen layer.
        document.apply(r.rig.content(layers: [r.rig.layer("changed by the source", version: "v2")]))
        #expect(document.selectedLayer?.markdown == "rendered")
        #expect(document.selectedLayer?.version == "v1")
        let outcome = await session.flush()
        let docID = try #require(outcome.docIDOfSeed)
        #expect(try r.store.revisions(of: docID).first?.body == "rendered")  // seeded from what was rendered
        #expect(try r.rig.head(docID).body == "rendered, typed")
        controller.onFocusChange(false)  // blur is a save point and must not throw
    }

    @Test func aSaveThatFailsKeepsTheTextForTheRetry() async throws {
        let r = try ReconRig()
        let doc = try r.rig.seededDocument(r.rig.layer("agent"))
        let session = NoteEditingSession(
            documentID: .live(r.key, layer: "notes"), writer: r.rig.writer(.existing(docID: doc.id)), model: nil,
            block: nil)
        try r.rig.failNextInsert(body: "boom")
        session.handle(NoteEditorEdit(text: "boom", range: 0..<4, changeInLength: 4))
        _ = await session.flush()
        #expect(session.saveFailed)
        try r.rig.clearFault()
        await session.retry()
        #expect(!session.saveFailed)
        #expect(try r.rig.head(doc.id).body == "boom")
    }
}
