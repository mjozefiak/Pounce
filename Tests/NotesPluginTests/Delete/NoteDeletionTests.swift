import Foundation
import LintelKit
import Synchronization
import Testing

@testable import NotesPlugin

/// Delete (spec step 4.6): the owner first, the overlays only after it succeeded, never without a confirmation.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct NoteDeletionTests {
    private func model(_ r: ReconRig, writing: Bool = true) -> NotesWorkspaceModel {
        var environment = NotesWorkspaceModel.Environment(library: r.library, pasteboard: RecordingPasteboard())
        environment.registry = r.registry
        let store = r.store
        let registry = r.registry
        let library = r.library
        environment.overlayHeads = { item in (try? NoteOverlayContent.heads(for: item, in: store)) ?? [] }
        environment.installHistory(store: { store })
        if writing {
            environment.installWriting(
                store: { store }, registry: r.registry, settings: r.rig.harness.settings, clock: r.rig.clock)
        }
        environment.canDeleteNotes = true
        environment.deleteNote = { item in
            try await NoteDeleter(library: library, store: store, registry: registry).delete(item)
        }
        let model = NotesWorkspaceModel(environment: environment)
        registry.onDiscard = { [weak model] items in model?.documentsDiscarded(items) }
        return model
    }

    /// A recorded note with an edited overlay (user writing): the copy Notes keeps.
    private func editedNote(_ r: ReconRig) async throws -> DocumentRecord {
        let layer = r.rig.layer("agent notes", version: "n1")
        r.publish([layer])
        return try await r.editedOverlay(layer, text: "my notes")
    }

    // MARK: Source first

    @Test func theOwnerDeletesFirstAndTheOverlaysGoOnlyAfterItSucceeded() async throws {
        let r = try ReconRig()
        let doc = try await editedNote(r)
        let store = r.store
        let key = r.key
        let seenAtDelete = Mutex<Bool?>(nil)
        r.source.onDelete = { _ in
            seenAtDelete.withLock { $0 = (try? store.liveDocument(key: key, layer: "notes")) != nil }
        }
        try await NoteDeleter(library: r.library, store: r.store, registry: r.registry).delete(.live(r.key))
        #expect(r.source.deleteCalls == 1)
        #expect(seenAtDelete.withLock { $0 } == true, "while the owner deletes, the copy in Notes is still there")
        #expect(try r.store.document(id: doc.id) == nil)
        #expect(try r.store.revisions(of: doc.id).isEmpty)
    }

    @Test func aFailingOwnerLeavesTheOverlayAndItsRevisionsUntouched() async throws {
        let r = try ReconRig()
        let doc = try await editedNote(r)
        let before = try r.store.revisions(of: doc.id)
        r.source.deleteFails = true
        await #expect(throws: NoteDeleter.Failure.sourceFailed) {
            try await NoteDeleter(library: r.library, store: r.store, registry: r.registry).delete(.live(r.key))
        }
        #expect(try r.store.revisions(of: doc.id) == before)
        #expect(try r.store.liveDocument(key: r.key, layer: "notes") != nil)
    }

    @Test func anOwnerThatIsOffLeavesEverythingAsItWas() async throws {
        let r = try ReconRig()
        let doc = try await editedNote(r)
        r.box.sources = []
        await #expect(throws: NoteDeleter.Failure.sourceUnavailable) {
            try await NoteDeleter(library: r.library, store: r.store, registry: r.registry).delete(.live(r.key))
        }
        #expect(try r.store.document(id: doc.id) != nil)
    }

    // MARK: Through the model: the sheet, the tab, the strip

    @Test func confirmingTheSheetDeletesTheNoteClosesItsTabAndSaysSo() async throws {
        let r = try ReconRig()
        let doc = try await editedNote(r)
        let model = model(r)
        let item = NoteItemID.live(r.key)
        await model.refresh()
        model.open(item)
        await model.loadContent(item)
        await model.requestDelete(item)
        let request = try #require(model.pendingDelete)
        #expect(request.subject == .meeting && request.hasEdits)
        #expect(r.source.deleteCalls == 0, "asking deletes nothing")
        await model.confirmDelete(request)
        #expect(r.source.deleteCalls == 1)
        #expect(model.pendingDelete == nil && model.documents[item] == nil && !model.tabs.contains(item))
        #expect(try r.store.document(id: doc.id) == nil)
        #expect(model.feedback == .deleted)
    }

    @Test func cancellingTheSheetDeletesNothing() async throws {
        let r = try ReconRig()
        let doc = try await editedNote(r)
        let model = model(r)
        await model.requestDelete(.live(r.key))
        #expect(model.pendingDelete != nil)
        model.cancelDelete()
        #expect(model.pendingDelete == nil && r.source.deleteCalls == 0)
        #expect(try r.store.document(id: doc.id) != nil)
    }

    @Test func aSourceFailureSaysSoAndKeepsTheTabAndTheCopy() async throws {
        let r = try ReconRig()
        let doc = try await editedNote(r)
        let model = model(r)
        let item = NoteItemID.live(r.key)
        await model.refresh()
        model.open(item)
        r.source.deleteFails = true
        await model.requestDelete(item)
        await model.confirmDelete(try #require(model.pendingDelete))
        #expect(model.feedback == .deleteFailed)
        #expect(model.strips.contains { $0.id == "feedback" })
        #expect(model.tabs.contains(item))
        #expect(try r.store.document(id: doc.id) != nil)
    }

    @Test func aMeetingBeingRecordedOrProcessedCannotBeDeleted() async throws {
        let r = try ReconRig()
        for state in [NoteState.recording, .processing] {
            r.publish([r.rig.layer("text")], state: state)
            let model = model(r)
            await model.refresh()
            #expect(!model.canDelete(.live(r.key)))
            await model.requestDelete(.live(r.key))
            #expect(model.pendingDelete == nil)
        }
        #expect(r.source.deleteCalls == 0)
    }

    @Test func theSheetNamesTheKindOfNote() async throws {
        let r = try ReconRig()
        r.publish([r.rig.layer("text")])
        let model = model(r)
        await model.refresh()
        await model.requestDelete(.live(r.key))
        #expect(model.pendingDelete?.subject == .meeting && model.pendingDelete?.hasEdits == false)
        let dictation = NoteKey(pluginID: "meetings", id: "d1")
        r.publish([r.rig.layer("text", id: "cleaned")], key: dictation)
        // A dictation is a dictation by its kind.
        let content = r.rig.content(key: dictation, layers: [r.rig.layer("text", id: "cleaned")])
        var summary = content.summary
        summary.kind = .dictation
        r.source.items = [summary]
        await model.refresh()
        await model.requestDelete(.live(dictation))
        #expect(model.pendingDelete?.subject == .dictation)
    }

    // MARK: Manual notes and copies of removed recordings

    @Test func aManualNoteIsDeletedWithoutAnyOwner() async throws {
        let r = try ReconRig()
        let manual = try r.store.createManualNote(now: Date(timeIntervalSince1970: 100))
        let model = model(r)
        await model.refresh()
        await model.requestDelete(.live(manual))
        #expect(model.pendingDelete?.subject == .manual)
        await model.confirmDelete(try #require(model.pendingDelete))
        #expect(try r.store.liveDocument(key: manual, layer: NotesStore.manualLayer) == nil)
        #expect(r.source.deleteCalls == 0)
    }

    @Test func deletingACopyOfARemovedRecordingKeepsTheOtherCopies() async throws {
        let r = try ReconRig()
        let first = try await editedNote(r)
        try r.store.detachReportingRows(r.key)
        // The same key, recreated: another recording with another start.
        let later = r.rig.started.addingTimeInterval(3600)
        let second = try r.rig.seededDocument(r.rig.layer("second", version: "n2"), startedAt: later)
        try r.store.detachReportingRows(r.key)
        let item = NoteItemID.detached(r.key, startedAtMs: NoteTime.milliseconds(r.rig.started))
        try await NoteDeleter(library: r.library, store: r.store, registry: r.registry).delete(item)
        #expect(try r.store.document(id: first.id) == nil)
        #expect(try r.store.document(id: second.id) != nil, "another recording's copy stays")
        #expect(r.source.deleteCalls == 0, "a recording that is gone has no owner to ask")
    }

    @Test func deletingTheNoteDiscardsTheTextStillBeingTyped() async throws {
        let r = try ReconRig()
        let doc = try await editedNote(r)
        let writer = r.registry.writer(for: .live(r.key, layer: "notes"), item: .live(r.key)) {
            r.rig.writer(.existing(docID: doc.id))
        }
        writer.submit("typed after the confirmation sheet opened")
        try await NoteDeleter(library: r.library, store: r.store, registry: r.registry).delete(.live(r.key))
        #expect(!writer.hasPendingText)
        #expect(r.registry.documentIDs.isEmpty)
        #expect(try r.store.document(id: doc.id) == nil)
    }

    // MARK: Titles of recorded notes

    @Test func aRecordedNotesTitleIsRenamedInItsOwnerNotInNotes() async throws {
        let r = try ReconRig()
        r.publish([r.rig.layer("text")])
        var environment = NotesWorkspaceModel.Environment(library: r.library, pasteboard: RecordingPasteboard())
        let source = r.source
        environment.renameTitle = { key, title in
            do {
                try await source.renameTitle(key, to: title)
                return true
            } catch { return false }
        }
        let model = NotesWorkspaceModel(environment: environment)
        await model.refresh()
        let item = NoteItemID.live(r.key)
        model.open(item)
        await model.loadContent(item)
        #expect(model.documents[item]?.canRenameTitle == true)
        await model.setTitle(item, to: "  A new title  ")
        #expect(source.renamedTitles.map(\.1) == ["A new title"])
        #expect(try r.store.liveDocument(key: r.key, layer: "notes") == nil, "nothing was written to notes.sqlite")
    }

    @Test func aFailedRenameSaysSoAndAnUnchangedTitleAsksNothing() async throws {
        let r = try ReconRig()
        r.publish([r.rig.layer("text")])
        var environment = NotesWorkspaceModel.Environment(library: r.library, pasteboard: RecordingPasteboard())
        let source = r.source
        source.renameFails = true
        environment.renameTitle = { key, title in
            do {
                try await source.renameTitle(key, to: title)
                return true
            } catch { return false }
        }
        let model = NotesWorkspaceModel(environment: environment)
        await model.refresh()
        let item = NoteItemID.live(r.key)
        model.open(item)
        await model.loadContent(item)
        await model.setTitle(item, to: "Different")
        #expect(model.feedback == .titleFailed)
        let current = model.row(for: item)?.summary.title ?? ""
        await model.setTitle(item, to: current)
        #expect(source.renamedTitles.count == 1)
    }
}

extension NoteDeletionTests {
    @Test func aFailedDeleteOfAManualNoteKeepsTheTextBeingTypedAndSaysSo() async throws {
        let r = try ReconRig()
        let manual = try r.store.createManualNote(now: Date(timeIntervalSince1970: 100))
        let docID = try #require(try r.store.liveDocument(key: manual, layer: NotesStore.manualLayer)).id
        let writer = r.registry.writer(for: .live(manual, layer: NotesStore.manualLayer), item: .live(manual)) {
            r.rig.writer(.existing(docID: docID))
        }
        writer.submit("typed, not yet saved")
        try r.store.close()
        await #expect(throws: NoteDeleter.Failure.copyNotDeleted) {
            try await NoteDeleter(library: r.library, store: r.store, registry: r.registry).delete(.live(manual))
        }
        #expect(writer.hasPendingText, "a failed delete never discards typed text")
        #expect(!r.registry.documentIDs.isEmpty)
    }

    @Test func aFailedDeleteOfAManualNoteSaysDeleteFailedNotOwnerDeleted() async throws {
        let r = try ReconRig()
        let manual = try r.store.createManualNote(now: Date(timeIntervalSince1970: 100))
        let model = model(r)
        await model.refresh()
        model.open(.live(manual))
        await model.requestDelete(.live(manual))
        let request = try #require(model.pendingDelete)
        try r.store.close()
        await model.confirmDelete(request)
        #expect(model.feedback == .deleteFailed)
        #expect(model.tabs.contains(.live(manual)))
    }
}
