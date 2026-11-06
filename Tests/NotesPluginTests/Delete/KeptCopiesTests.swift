import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

/// "N copies in Notes are kept" and "Also delete kept copies" (owner decision L1-39), as the source plugins ask
/// for them through the shell.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct KeptCopiesTests {
    private struct Rig {
        let plugin: NotesPlugin
        let store: NotesStore?
        let source: ScriptedNoteSource
        let storage: URL
        let keychain: CountingKeychain
    }

    private func rig(openStore: Bool = true) throws -> Rig {
        let storage = FileManager.default.temporaryDirectory.appending(
            path: "lintel-notes-kept-\(UUID().uuidString)", directoryHint: .isDirectory)
        let keychain = CountingKeychain()
        let source = ScriptedNoteSource("meetings")
        let plugin = NotesPlugin(
            context: makeContext(storage: storage, keychain: keychain, noteSources: { [source] }))
        if openStore { plugin.library.open() }
        return Rig(plugin: plugin, store: plugin.library.store, source: source, storage: storage, keychain: keychain)
    }

    /// An overlay of a meeting; `edited` makes it user writing (a kept copy).
    @discardableResult
    private func overlay(
        _ r: Rig, id: String, edited: Bool, startedAt: Date, detached: Bool = false, publish: Bool = true
    ) throws -> Int64 {
        let key = NoteKey(pluginID: "meetings", id: id)
        let layer = NoteLayer(id: "notes", author: .agent, markdown: "agent \(id)", provenance: [], version: "v1")
        let content = NoteContent(
            summary: NoteSummary(id: key, kind: .meeting, title: id, startedAt: startedAt, state: .ready),
            layers: [layer], speakers: [])
        if publish {
            r.source.contents[key] = content
            r.source.items = r.source.items.filter { $0.id != key } + [content.summary]
        }
        let plan = try #require(OverlaySeeder.plan(content: content, layerID: "notes"))
        let doc = try OverlaySeeder.seed(plan, in: try #require(r.store), now: Date(timeIntervalSince1970: 100))
        if edited {
            let attribution = BlockAttribution().stored(body: "edited \(id)", author: "human", previous: [])
            try try #require(r.store).appendRevision(
                NewNoteRevision(
                    docID: doc.id, author: "human", state: .applied, body: "edited \(id)",
                    blocksJSON: attribution.json, now: Date(timeIntervalSince1970: 200),
                    expectedHeadID: doc.headRevisionID))
        }
        if detached { try try #require(r.store).detachReportingRows(key) }
        return doc.id
    }

    private let started = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theCountNeverCreatesTheStoreOrTouchesTheKeychain() async throws {
        let r = try rig(openStore: false)
        defer { try? FileManager.default.removeItem(at: r.storage) }
        #expect(await r.plugin.keptNoteCopyCount(ofOwner: "meetings") == 0)
        #expect(await r.plugin.deleteKeptNoteCopies(ofOwner: "meetings", ownerErased: false))
        #expect(r.keychain.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: r.storage.path))
    }

    @Test func onlyEditedCopiesOfThatOwnerAreCounted() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.storage) }
        try overlay(r, id: "kept-1", edited: true, startedAt: started)
        try overlay(r, id: "kept-2", edited: true, startedAt: started.addingTimeInterval(10), detached: true)
        try overlay(r, id: "plain", edited: false, startedAt: started.addingTimeInterval(20))
        #expect(await r.plugin.keptNoteCopyCount(ofOwner: "meetings") == 2)
        #expect(await r.plugin.keptNoteCopyCount(ofOwner: "dictation") == 0)
        #expect(await r.plugin.keptNoteCopyCount(ofOwner: "notes") == 0)
    }

    @Test func withTheBoxTheCopiesOfRecordingsThatAreGoneAreDeletedAndTheOthersStay() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.storage) }
        let gone = try overlay(r, id: "gone", edited: true, startedAt: started)
        let stays = try overlay(r, id: "stays", edited: true, startedAt: started.addingTimeInterval(10))
        // The owner cleared its library: only "stays" still exists (a meeting that was being recorded).
        r.source.existing = [NoteKey(pluginID: "meetings", id: "stays")]
        #expect(await r.plugin.deleteKeptNoteCopies(ofOwner: "meetings", ownerErased: false))
        #expect(try try #require(r.store).document(id: gone) == nil)
        #expect(try try #require(r.store).document(id: stays) != nil)
    }

    @Test func anOwnerThatCannotAnswerLosesNoCopy() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.storage) }
        let copy = try overlay(r, id: "m", edited: true, startedAt: started)
        r.source.existsBehavior = .throwsError
        #expect(await r.plugin.deleteKeptNoteCopies(ofOwner: "meetings", ownerErased: false))
        #expect(try try #require(r.store).document(id: copy) != nil, "unknown is not gone")
    }

    @Test func aDetachedCopyOfTheOwnerIsDeletedAndAnotherOwnersStays() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.storage) }
        let detached = try overlay(r, id: "old", edited: true, startedAt: started, detached: true)
        let manual = try try #require(r.store).createManualNote(now: Date(timeIntervalSince1970: 1))
        #expect(await r.plugin.deleteKeptNoteCopies(ofOwner: "meetings", ownerErased: false))
        #expect(try try #require(r.store).document(id: detached) == nil)
        #expect(
            try try #require(r.store).liveDocument(key: manual, layer: NotesStore.manualLayer) != nil,
            "your own notes stay")
    }

    @Test func afterEraseDataEveryCopyOfThatOwnerGoesButNeverAManualNote() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.storage) }
        let live = try overlay(r, id: "live", edited: true, startedAt: started)
        let manual = try try #require(r.store).createManualNote(now: Date(timeIntervalSince1970: 1))
        #expect(await r.plugin.deleteKeptNoteCopies(ofOwner: "meetings", ownerErased: true))
        #expect(try try #require(r.store).document(id: live) == nil)
        #expect(try try #require(r.store).liveDocument(key: manual, layer: NotesStore.manualLayer) != nil)
    }

    @Test func aCopyOpenInATabClosesItsTabWithoutWritingItAgain() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.storage) }
        let docID = try overlay(r, id: "open", edited: true, startedAt: started, detached: true)
        let writer = RevisionWriter(store: try #require(r.store), target: .existing(docID: docID))
        let item = NoteItemID.detached(
            NoteKey(pluginID: "meetings", id: "open"), startedAtMs: NoteTime.milliseconds(started))
        _ = r.plugin.documents.writer(for: .detached(docID: docID), item: item) { writer }
        writer.submit("typed")
        var discarded: Set<NoteItemID> = []
        r.plugin.documents.onDiscard = { discarded = $0 }
        #expect(await r.plugin.deleteKeptNoteCopies(ofOwner: "meetings", ownerErased: false))
        #expect(discarded == [item])
        #expect(!writer.hasPendingText)
        #expect(try try #require(r.store).document(id: docID) == nil)
    }
}
