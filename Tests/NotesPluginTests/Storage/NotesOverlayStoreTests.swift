import Foundation
import GRDB
import LintelKit
import Testing

@testable import NotesPlugin

@MainActor
@Suite(.timeLimit(.minutes(1))) struct NotesOverlayStoreTests {
    private let meeting = NoteKey(pluginID: "meetings", id: "m1")

    @Test func userWritingIsOneDefinition() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        let seeded = try store.insertDocument(.overlay("seed", author: "agent"))  // agent seed only
        let human = try store.insertDocument(.overlay("human", author: "agent"))
        try store.appendRevision(
            NewNoteRevision(
                docID: human.docID, author: "human", state: .applied, body: "edit", now: Date(),
                expectedHeadID: human.revisionID))
        let revise = try store.insertDocument(.overlay("revise", author: "agent"))
        try store.appendRevision(
            NewNoteRevision(
                docID: revise.docID, author: "agent", state: .applied, body: "revised",
                metaJSON: #"{"comment_ids":[1]}"#, now: Date(), expectedHeadID: revise.revisionID))
        let regen = try store.insertDocument(.overlay("regen", author: "agent"))
        try store.appendRevision(
            NewNoteRevision(
                docID: regen.docID, author: "agent", state: .applied, body: "regen",
                metaJSON: #"{"model":"x"}"#, now: Date(), expectedHeadID: regen.revisionID))
        let proposed = try store.insertDocument(.overlay("proposed", author: "agent"))
        try store.appendRevision(
            NewNoteRevision(
                docID: proposed.docID, author: "human", state: .proposed, body: "lost", now: Date(), expectedHeadID: nil
            ))
        let discarded = try store.insertDocument(.overlay("discarded", author: "agent"))
        try store.appendRevision(
            NewNoteRevision(
                docID: discarded.docID, author: "human", state: .discarded, body: "gone", now: Date(),
                expectedHeadID: nil))

        let kept = Dictionary(
            uniqueKeysWithValues: try store.keptOverlays(excludingPlugins: []).map { ($0.key.id, $0.isKept) })
        #expect(Set(kept.keys) == ["human", "revise"])
        let all = try store.liveOverlays(
            for: ["seed", "human", "revise", "regen", "proposed", "discarded"].map {
                NoteKey(pluginID: "meetings", id: $0)
            })
        #expect(all.count == 6)
        #expect(Set(all.filter(\.isKept).map(\.key.id)) == ["human", "revise"])
        _ = seeded
    }

    @Test func anOpenCommentKeepsAnOverlayAndAResolvedOneDoesNot() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        let doc = try store.insertDocument(.overlay("m1", author: "agent"))
        func comment(_ status: String) throws {
            try store.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO note_comment(doc_id, thread_id, author, created_at, body, anchor_revision_id,
                            anchor_start, anchor_end, anchor_block_hash, anchor_quote, status)
                        VALUES (?, 1, 'human', 0, 'c', ?, 0, 1, 'h', 'q', ?)
                        """, arguments: [doc.docID, doc.revisionID, status])
            }
        }
        try comment("resolved")
        #expect(try store.keptOverlays(excludingPlugins: []).isEmpty)
        try comment("open")
        #expect(try store.keptOverlays(excludingPlugins: []).count == 1)
        #expect(try store.keptOverlays(excludingPlugins: ["meetings"]).isEmpty)
    }

    @Test func theOverlayPortsReadMetadataOnly() async throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        try store.insertDocument(.manual("n1", body: "secret body", title: "Secret title"))
        try store.insertDocument(.overlay("m1", layer: "notes", startedAtMs: 5_000))
        try store.insertDocument(.overlay("m2", layer: "notes", startedAtMs: 6_000, state: .detached))
        let index = StoreOverlayIndex(store: store)

        let manual = try await index.manualNotes()
        #expect(manual.map(\.title) == ["Secret title"])
        #expect(manual.first?.kind == .manual)
        #expect(manual.first?.startedAtMs == nil)
        let live = try await index.overlays(for: [meeting, NoteKey(pluginID: "meetings", id: "none")])
        #expect(live.map(\.layer) == ["notes"])
        #expect(live.first?.startedAtMs == 5_000)
        #expect(try await index.detachedOverlays().map(\.key.id) == ["m2"])
        #expect(try await index.liveOverlayKeys() == [meeting])
        #expect(try await index.overlays(for: []).isEmpty)
    }

    @Test func detachMovesEveryLiveLayerOfTheKeyAndNothingElse() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        try store.insertDocument(.overlay("m1", layer: "notes"))
        try store.insertDocument(.overlay("m1", layer: "transcript"))
        try store.insertDocument(.overlay("m2", layer: "notes"))
        try store.insertDocument(.manual("m1"))  // key "notes:m1" differs, never detached
        #expect(try store.detach(meeting) == 2)
        #expect(try store.detachedOverlays().map(\.layer).sorted() == ["notes", "transcript"])
        #expect(try store.liveOverlays(for: [NoteKey(pluginID: "meetings", id: "m2")]).count == 1)
        #expect(try store.manualOverlays().count == 1)
        #expect(try store.detach(meeting) == 0)
    }

    @Test func theDetachAndTheOverlayUpdateRunInOneTransaction() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        let doc = try store.insertDocument(.overlay("m1", layer: "notes", body: "before"))
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try store.detach(meeting) { db in
                try db.execute(
                    sql: "UPDATE note_doc SET source_version_seen = 'changed' WHERE id = ?", arguments: [doc.docID])
                throw Boom()
            }
        }
        // Nothing was detached and the update was rolled back with it.
        #expect(try store.detachedOverlays().isEmpty)
        let seen = try store.read { db in try String.fetchOne(db, sql: "SELECT source_version_seen FROM note_doc") }
        #expect(seen == "v1")

        try store.detach(meeting) { db in
            try db.execute(
                sql: "UPDATE note_doc SET source_version_seen = 'changed' WHERE id = ?", arguments: [doc.docID])
        }
        #expect(try store.detachedOverlays().count == 1)
        #expect(
            try store.read { db in try String.fetchOne(db, sql: "SELECT source_version_seen FROM note_doc") }
                == "changed")
    }

    @Test func detachedRowsWithoutKeepingAreDeletedUnlessOpen() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        let plain = try store.insertDocument(.overlay("a", state: .detached))
        let open = try store.insertDocument(.overlay("b", state: .detached))
        let edited = try store.insertDocument(.overlay("c", author: "human", state: .detached))
        let live = try store.insertDocument(.overlay("d"))
        #expect(try store.deleteUnkeptDetached(excluding: [open.docID]) == 1)
        let remaining = try store.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM note_doc ORDER BY id") }
        #expect(remaining == [open.docID, edited.docID, live.docID])
        #expect(!remaining.contains(plain.docID))
        #expect(try store.deleteUnkeptDetached() == 1)  // the one that was open goes once it is closed
    }

    @Test func deletingLiveOverlaysLeavesDetachedOnes() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        try store.insertDocument(.overlay("m1", layer: "notes"))
        try store.insertDocument(.overlay("m1", layer: "notes", startedAtMs: 9, state: .detached))
        #expect(try store.deleteLiveOverlays(of: meeting) == 1)
        #expect(try store.detachedOverlays().count == 1)
    }

    @Test func aStoredKeyThatIsNotAKeyIsSkipped() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        try store.write { db in
            try db.execute(
                sql: """
                    INSERT INTO note_doc(key, layer, kind, source_plugin_id, head_revision_id, created_at, updated_at)
                    VALUES ('garbage', 'notes', 'meeting', 'meetings', 0, 0, 0)
                    """)
        }
        #expect(try store.liveOverlays(for: [NoteKey(pluginID: "meetings", id: "x")]).isEmpty)
        #expect(try store.keptOverlays(excludingPlugins: []).isEmpty)
        #expect(NoteKey(rawValue: "garbage") == nil)
        #expect(NoteKey(rawValue: "meetings:abc")?.id == "abc")
    }
}
