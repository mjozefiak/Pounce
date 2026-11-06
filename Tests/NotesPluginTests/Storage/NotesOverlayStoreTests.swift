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

    @Test func aProposedHumanRevisionIsUserWritingAndKeepsADetachedRow() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        let row = try store.insertDocument(.overlay("p", state: .detached))
        #expect(!(try store.hasUserWriting(row.docID)))
        try store.appendRevision(
            NewNoteRevision(
                docID: row.docID, author: "human", state: .proposed, body: "kept after a lost compare-and-set",
                now: Date()))
        #expect(try store.hasUserWriting(row.docID))
        #expect(try store.deleteUnkeptDetached() == 0)
        #expect(try store.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM note_doc") } == [row.docID])
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

    @Test func aStartedAtMismatchDetachesUnderReadOnlyAndShowsAsDetachedUnderANewerSchema() async throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let first = harness.opener()
        first.open()
        let store = try #require(first.store)
        try store.insertDocument(.overlay("m1", layer: "notes", author: "human", startedAtMs: 1_000))
        let source = ScriptedNoteSource("meetings", items: [Fixtures.summary("meetings", "m1", secondsAgo: 10)])

        // readOnly on: the detach still works (it only re-keys).
        harness.settings.set(true, for: NotesSettingsKey.readOnly)
        let index = StoreOverlayIndex(store: store)
        let library = NoteLibrary(sources: { [source] }, overlays: index, detacher: index)
        let listing = await library.list(matching: nil, after: nil, limit: 5)
        #expect(listing.rows.count == 2)
        #expect(try store.detachedOverlays().count == 1)
        #expect(try store.liveOverlays(for: [meeting]).isEmpty)

        // A newer schema: the detach throws, the old text is still shown as detached, never as live.
        let second = try NotesHarness()
        defer { withExtendedLifetime(second) {} }
        let other = second.opener()
        other.open()
        let newer = try #require(other.store)
        try newer.insertDocument(.overlay("m1", layer: "notes", author: "human", startedAtMs: 1_000))
        try newer.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v2-future')")
        }
        other.close()
        let reopened = second.opener()
        reopened.open()
        let frozen = try #require(reopened.store)
        let frozenIndex = StoreOverlayIndex(store: frozen)
        let frozenLibrary = NoteLibrary(sources: { [source] }, overlays: frozenIndex, detacher: frozenIndex)
        let rows = await frozenLibrary.list(matching: nil, after: nil, limit: 5).rows
        #expect(rows.count == 2)
        #expect(rows[0].overlays.isEmpty)
        #expect(rows[1].badge == .recordingRemoved)
        #expect(try frozen.detachedOverlays().isEmpty)
    }

    @Test func aMalformedMetaJSONNeverMakesListingsOrTheRetentionDeleteThrow() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        let bad = try store.insertDocument(.overlay("bad", author: "agent", state: .detached))
        let good = try store.insertDocument(.overlay("good", author: "agent", state: .detached))
        try store.write { db in
            try db.execute(
                sql: "UPDATE note_revision SET meta_json = '{not json' WHERE doc_id = ?", arguments: [bad.docID])
            try db.execute(
                sql: "UPDATE note_revision SET meta_json = '{\"comment_ids\":[1]}' WHERE doc_id = ?",
                arguments: [good.docID])
        }
        #expect(try store.detachedOverlays().map(\.isKept).sorted { !$0 && $1 } == [false, true])
        #expect(try store.keptOverlays(excludingPlugins: []).isEmpty)  // both are detached, not live
        #expect(try store.deleteUnkeptDetached() == 1)
        #expect(try store.detachedOverlays().map(\.docID) == [good.docID])
    }
}
