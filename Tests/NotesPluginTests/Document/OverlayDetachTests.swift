import Foundation
import GRDB
import LintelKit
import Testing

@testable import NotesPlugin

@MainActor
@Suite(.timeLimit(.minutes(1))) struct OverlayDetachTests {
    private func startedMs(_ r: ReconRig) -> Int64 { NoteTime.milliseconds(r.rig.started) }

    @Test func aCommentWithoutEditingThenTheSourceDeletedIsListedAsRecordingRemovedAndDeleteRemovesIt() async throws {
        let r = try ReconRig()
        let seed = try r.rig.seededDocument(r.rig.layer("agent notes"))
        try r.rig.addComment(doc: seed.id, anchorRevision: seed.headRevisionID)
        r.source.existing = []
        #expect(await r.reconciler.sweep() == [r.key])
        let listing = await r.library.list(matching: nil, after: nil, limit: 50)
        #expect(listing.rows.count == 1)
        let row = try #require(listing.rows.first)
        #expect(row.id == .detached(r.key, startedAtMs: startedMs(r)))
        #expect(row.badge == .recordingRemoved)
        // Delete of a detached overlay removes the overlay and never calls the source.
        try r.store.deleteDocument(seed.id)
        #expect(await r.library.list(matching: nil, after: nil, limit: 50).rows.isEmpty)
        #expect(r.source.deleteCalls == 0)
    }

    @Test func aMergeThatDetachesAnOpenDirtyOverlayFlushesItAndTheTypedTextLandsInTheDetachedDocument() async throws {
        let r = try ReconRig()
        let layer = r.rig.layer("agent notes", version: "v1")
        let seed = try r.rig.seededDocument(layer)
        let live = NoteDocumentID.live(r.key, layer: "notes")
        let writer = r.registry.writer(for: live, item: .live(r.key)) { r.rig.writer(.existing(docID: seed.id)) }
        writer.submit("typed before the detach")
        // The same key now names another recording (a recreated store's row 1).
        let newStart = r.rig.started.addingTimeInterval(3600)
        r.publish([r.rig.layer("brand new notes", version: "w1")], startedAt: newStart)
        let listing = await r.library.list(matching: nil, after: nil, limit: 50)
        #expect(listing.rows.count == 2)  // the new live note and the detached one: never merged by key
        #expect(try r.store.document(id: seed.id)?.sourceState == .detached)
        #expect(try r.rig.head(seed.id).body == "typed before the detach")
        #expect(r.registry.writer(for: .detached(docID: seed.id)) === writer)
        #expect(r.registry.writer(for: live) == nil)
        #expect(!writer.hasPendingText)
        // Opening the new row 1 creates a new document with a new writer; typing in one leaves the other alone.
        let content = r.rig.content(layers: [r.rig.layer("brand new notes", version: "w1")], startedAt: newStart)
        let plan = try #require(OverlaySeeder.plan(content: content, layerID: "notes"))
        let fresh = r.registry.writer(for: live, item: .live(r.key)) { r.rig.writer(.seed(plan)) }
        #expect(fresh !== writer)
        fresh.submit("typed in the new note")
        let newDoc = try #require(try await fresh.flush().docIDOfSeed)
        #expect(newDoc != seed.id)
        #expect(try r.rig.head(seed.id).body == "typed before the detach")
        #expect(try r.rig.head(newDoc).body == "typed in the new note")
        writer.submit("more in the old one")
        try await writer.flush()
        #expect(try r.rig.head(newDoc).body == "typed in the new note")
    }

    @Test func anOpenOverlayWithoutUserWritingIsNotDeletedUntilItsTabCloses() async throws {
        let r = try ReconRig()
        let seed = try r.rig.seededDocument(r.rig.layer("agent notes"))
        _ = r.registry.writer(for: .live(r.key, layer: "notes"), item: .live(r.key)) {
            r.rig.writer(.existing(docID: seed.id))
        }
        r.source.existing = []
        await r.reconciler.sweep()
        #expect(try r.store.document(id: seed.id)?.sourceState == .detached)  // still there: its tab is open
        await r.registry.release(item: .detached(r.key, startedAtMs: startedMs(r)))
        #expect(try r.store.document(id: seed.id) == nil)
    }

    @Test func aQuitWithThatTabOpenDeletesTheRowOnStoreOpenAndExportSkipsIt() async throws {
        let r = try ReconRig()
        let seed = try r.rig.seededDocument(r.rig.layer("agent notes"))
        let other = try r.store.insertDocument(.manual("manual"))
        _ = r.registry.writer(for: .live(r.key, layer: "notes"), item: .live(r.key)) {
            r.rig.writer(.existing(docID: seed.id))
        }
        r.source.existing = []
        await r.reconciler.sweep()
        #expect(try r.store.document(id: seed.id) != nil)
        #expect(try r.store.exportableDocumentIDs() == [other.docID])  // Export All skips the leftover
        // Simulated quit: `deactivate()` flushes the registry and closes the store; the next launch reopens it.
        await r.registry.flushAll()
        try r.store.close()
        let reopened = try r.rig.harness.openStore()
        #expect(try reopened.document(id: seed.id) == nil)
        #expect(try reopened.document(id: other.docID) != nil)
    }

    @Test func aRecreatedStoreWithTheSameKeyDetachesOnOpenBeforeAnySeedAndLeavesTwoIndependentDocuments() async throws {
        let r = try ReconRig()
        let old = try await r.editedOverlay(r.rig.layer("old recording", version: "v1"), text: "my corrections")
        let newStart = r.rig.started.addingTimeInterval(86_400)
        let newLayer = r.rig.layer("the new row one", version: "n1")
        r.publish([newLayer], startedAt: newStart)
        #expect(await r.reconciler.reconcile(r.key) == .detached)  // `content(for:)` on open
        #expect(try r.store.document(id: old.id)?.sourceState == .detached)
        #expect(try NoteOverlayContent.heads(for: .live(r.key), in: r.store).isEmpty)  // shows the source text
        let content = try #require(r.source.contents[r.key])
        let shown = try #require(
            NoteOverlayContent.compose(item: .live(r.key), source: content, heads: [], summary: nil))
        #expect(shown.layers.first?.markdown == "the new row one")
        // It can be seeded and edited; the detached one is untouched; deleting it leaves the new row.
        let plan = try #require(OverlaySeeder.plan(content: content, layerID: "notes"))
        let writer = r.rig.writer(.seed(plan))
        writer.submit("the new row one, edited")
        let newDoc = try #require(try await writer.flush().docIDOfSeed)
        #expect(try r.rig.head(old.id).body == "my corrections")
        try r.store.deleteDocument(old.id)
        #expect(try r.store.liveDocument(key: r.key, layer: "notes")?.id == newDoc)
        #expect(r.source.deleteCalls == 0)
    }

    @Test func anErasedSourceWithANewKeyLeavesTheOldOverlayDetached() async throws {
        let r = try ReconRig()
        let old = try await r.editedOverlay(r.rig.layer("old", version: "v1"), text: "mine")
        let fresh = NoteKey(pluginID: "meetings", id: "m-after-erase")
        r.publish([r.rig.layer("new", version: "v1")], key: fresh)
        r.source.existing = [fresh]
        #expect(await r.reconciler.sweep() == [r.key])
        let listing = await r.library.list(matching: nil, after: nil, limit: 50)
        #expect(Set(listing.rows.map(\.id)) == [.live(fresh), .detached(r.key, startedAtMs: startedMs(r))])
        #expect(try r.store.document(id: old.id)?.sourceState == .detached)
    }

    @Test func aDetachThatThrowsDetachesNothing() async throws {
        let r = try ReconRig()
        let doc = try await r.editedOverlay(r.rig.layer("old", version: "n1"))
        let layer = r.rig.layer("old", version: "n1")
        let writer = r.registry.writer(for: .live(r.key, layer: "notes"), item: .live(r.key)) {
            r.rig.writer(.existing(docID: doc.id))
        }
        try r.rig.failNextInsert(body: "can not be flushed")
        writer.submit("can not be flushed")
        r.publish([layer], startedAt: r.rig.started.addingTimeInterval(3600))
        // The flush before the detach fails, so nothing is detached and the text is still buffered.
        #expect(await r.reconciler.reconcile(r.key) == .unavailable)
        #expect(try r.store.document(id: doc.id)?.sourceState == .present)
        #expect(writer.hasPendingText)
    }

    @Test func aNoteOpenTwiceIsOneDocumentWithOneWriter() throws {
        let r = try ReconRig()
        let seed = try r.rig.seededDocument(r.rig.layer("agent notes"))
        let id = NoteDocumentID.live(r.key, layer: "notes")
        let first = r.registry.writer(for: id, item: .live(r.key)) { r.rig.writer(.existing(docID: seed.id)) }
        let second = r.registry.writer(for: id, item: .live(r.key)) { r.rig.writer(.existing(docID: seed.id)) }
        #expect(first === second)
        #expect(r.registry.documentIDs == [id])
    }

    @Test func detachedDocumentsAreTwoRowsWithTwoWritersForTwoLayers() async throws {
        let r = try ReconRig()
        let notes = try await r.editedOverlay(r.rig.layer("n", version: "n1"))
        let transcript = try await r.editedOverlay(r.rig.layer("t", id: "transcript", version: "t1", author: .stt))
        r.source.existing = []
        await r.reconciler.sweep()
        let listing = await r.library.list(matching: nil, after: nil, limit: 50)
        #expect(listing.rows.count == 1)  // one "Recording removed" row with two layers
        #expect(listing.rows.first?.overlays.count == 2)
        let heads = try NoteOverlayContent.heads(for: .detached(r.key, startedAtMs: startedMs(r)), in: r.store)
        #expect(Set(heads.map(\.layerID)) == ["notes", "transcript"])
        _ = (notes, transcript)
    }
}
