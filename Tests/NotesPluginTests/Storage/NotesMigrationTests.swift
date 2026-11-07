import Foundation
import GRDB
import LintelKit
import Testing

@testable import NotesPlugin

@MainActor
@Suite(.timeLimit(.minutes(1))) struct NotesMigrationTests {
    private func names(_ store: NotesStore, type: String) throws -> Set<String> {
        try store.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = ?", arguments: [type]))
        }
    }

    @Test func aNewDatabaseGetsTheWholeSchema() throws {
        let harness = try NotesHarness()
        let store = try harness.openStore()
        let tables = try names(store, type: "table")
        #expect(["note_doc", "note_revision", "note_comment", "note_fts"].allSatisfy(tables.contains))
        #expect(try names(store, type: "view") == ["note_fts_source"])
        #expect(try names(store, type: "index").contains("note_doc_live"))
        let applied = try store.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied == ["v1-notes"])
        #expect(!store.hasNewerSchema)
    }

    @Test func aPopulatedDatabaseOpensAgainWithItsRowsAndWithoutRunningTheMigrationTwice() throws {
        let harness = try NotesHarness()
        let first = harness.opener()
        first.open()
        let store = try #require(first.store)
        let doc = try store.insertDocument(.manual("a", body: "kept text", title: "Title"))
        try store.insertDocument(.overlay("m1"))
        first.close()

        let second = harness.opener()
        second.open()
        let reopened = try #require(second.store)
        #expect(second.status == .ready)
        #expect(try reopened.manualOverlays().map(\.docID) == [doc.docID])
        #expect(try reopened.liveOverlays(for: [NoteKey(pluginID: "meetings", id: "m1")]).count == 1)
        #expect(try reopened.search("kept").count == 1)
        let applied = try reopened.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied == ["v1-notes"])
    }

    @Test func theMigratorOnlyKnowsV1Notes() {
        #expect(NotesStore.migrator.migrations == ["v1-notes"])
    }

    // MARK: CHECKs

    @Test func everyClosedStateIsCheckedAndOpenSetsAreNot() throws {
        let harness = try NotesHarness()
        let store = try harness.openStore()
        let doc = try store.insertDocument(.manual("a"))

        #expect(throws: DatabaseError.self) {
            try store.write { db in
                try db.execute(sql: "UPDATE note_doc SET source_state = 'gone' WHERE id = ?", arguments: [doc.docID])
            }
        }
        #expect(throws: DatabaseError.self) {
            try store.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO note_revision(doc_id, seq, author, state, created_at, body_markdown)
                        VALUES (?, 9, 'human', 'bogus', 0, '')
                        """, arguments: [doc.docID])
            }
        }
        #expect(throws: DatabaseError.self) {
            try store.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO note_comment(doc_id, thread_id, author, created_at, body, anchor_revision_id,
                            anchor_start, anchor_end, anchor_block_hash, anchor_quote, status)
                        VALUES (?, 1, 'human', 0, 'c', ?, 0, 1, 'h', 'q', 'closed')
                        """, arguments: [doc.docID, doc.revisionID])
            }
        }
        #expect(throws: DatabaseError.self) {
            try store.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO note_comment(doc_id, thread_id, author, created_at, body, anchor_revision_id,
                            anchor_start, anchor_end, anchor_block_hash, anchor_quote)
                        VALUES (?, 1, 'human', 0, 'c', ?, 5, 2, 'h', 'q')
                        """, arguments: [doc.docID, doc.revisionID])
            }
        }
        // Open sets: an unknown kind, layer, author and key prefix are accepted (validated in Swift).
        var other = NewNoteDocument.overlay("x", layer: "future-layer", author: "future-author", plugin: "newplugin")
        other.kind = NoteKind(rawValue: "future-kind")
        try store.insertDocument(other)
    }

    @Test func aRevisionNumberIsUniquePerDocument() throws {
        let harness = try NotesHarness()
        let store = try harness.openStore()
        let a = try store.insertDocument(.manual("a"))
        let b = try store.insertDocument(.manual("b"))
        #expect(throws: DatabaseError.self) {
            try store.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO note_revision(doc_id, seq, author, state, created_at, body_markdown)
                        VALUES (?, 1, 'human', 'applied', 0, '')
                        """, arguments: [a.docID])
            }
        }
        // The same number in another document is fine.
        try store.write { db in
            try db.execute(
                sql: """
                    INSERT INTO note_revision(doc_id, seq, author, state, created_at, body_markdown)
                    VALUES (?, 2, 'human', 'applied', 0, '')
                    """, arguments: [b.docID])
            try db.execute(
                sql: """
                    INSERT INTO note_revision(doc_id, seq, author, state, created_at, body_markdown)
                    VALUES (?, 2, 'human', 'applied', 0, '')
                    """, arguments: [a.docID])
        }
    }

    @Test func aLiveOverlayIsUniquePerKeyAndLayerButADetachedOneDoesNotBlockIt() throws {
        let harness = try NotesHarness()
        let store = try harness.openStore()
        try store.insertDocument(.overlay("m1", layer: "notes"))
        #expect(throws: DatabaseError.self) { try store.insertDocument(.overlay("m1", layer: "notes")) }
        try store.insertDocument(.overlay("m1", layer: "transcript"))
        // Two manual notes with the same key and layer are a defect too (state NULL counts as live).
        try store.insertDocument(.manual("n1"))
        #expect(throws: DatabaseError.self) { try store.insertDocument(.manual("n1")) }

        try store.detach(NoteKey(pluginID: "meetings", id: "m1"))
        // A detached row and a live row with one key coexist; so do two detached ones.
        try store.insertDocument(.overlay("m1", layer: "notes", startedAtMs: 2_000))
        try store.insertDocument(.overlay("m1", layer: "notes", startedAtMs: 3_000, state: .detached))
        try store.insertDocument(.overlay("m1", layer: "notes", startedAtMs: 4_000, state: .detached))
        let rows = try store.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM note_doc WHERE key = 'meetings:m1' AND layer = 'notes'")
        }
        #expect(rows == 4)
    }

    @Test func deletingADocumentCascadesToItsRevisionsCommentsAndIndexRow() throws {
        let harness = try NotesHarness()
        let store = try harness.openStore()
        let doc = try store.insertDocument(.manual("a", body: "findme"))
        try store.appendRevision(
            NewNoteRevision(
                docID: doc.docID, author: "agent", state: .proposed, body: "p", now: Date(), expectedHeadID: nil))
        try store.write { db in
            try db.execute(
                sql: """
                    INSERT INTO note_comment(doc_id, thread_id, author, created_at, body, anchor_revision_id,
                        anchor_start, anchor_end, anchor_block_hash, anchor_quote)
                    VALUES (?, 1, 'human', 0, 'c', ?, 0, 1, 'h', 'q')
                    """, arguments: [doc.docID, doc.revisionID])
        }
        #expect(try store.search("findme").count == 1)
        try store.deleteDocument(doc.docID)
        let counts = try store.read { db in
            try [
                Int.fetchOne(db, sql: "SELECT count(*) FROM note_doc"),
                Int.fetchOne(db, sql: "SELECT count(*) FROM note_revision"),
                Int.fetchOne(db, sql: "SELECT count(*) FROM note_comment"),
                Int.fetchOne(db, sql: "SELECT count(*) FROM note_fts"),
            ]
        }
        #expect(counts == [0, 0, 0, 0])
        #expect(try store.search("findme").isEmpty)
    }

    @Test func compareAndSetMovesTheHeadOnlyFromTheExpectedOne() throws {
        let harness = try NotesHarness()
        let store = try harness.openStore()
        let doc = try store.insertDocument(.manual("a", body: "one"))
        let second = try store.appendRevision(
            NewNoteRevision(
                docID: doc.docID, author: "human", state: .applied, body: "two", now: Date(),
                expectedHeadID: doc.revisionID))
        #expect(throws: NotesError.casConflict) {
            try store.appendRevision(
                NewNoteRevision(
                    docID: doc.docID, author: "agent", state: .applied, body: "three", now: Date(),
                    expectedHeadID: doc.revisionID))
        }
        let state = try store.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT d.head_revision_id AS head, (SELECT count(*) FROM note_revision) AS revisions FROM note_doc d
                    """)
        }
        #expect(state?["head"] == second)
        #expect(state?["revisions"] == 2)  // the lost write was rolled back with its transaction
    }
}
