import Foundation
import GRDB
import LintelKit
import Testing

@testable import NotesPlugin

@MainActor
@Suite(.timeLimit(.minutes(1))) struct NotesFoldingTests {
    /// The view of migration `v1-notes`, written out letter by letter. Never edit: a new folding needs a new
    /// migration (the way `v1-meetings` is pinned).
    static let frozenViewSQL = """
        CREATE VIEW note_fts_source AS
                        SELECT d.id AS id, replace(replace(replace(replace(replace(replace(COALESCE(d.title_override, ''), 'ł', 'l'), 'Ł', 'L'), 'đ', 'd'), 'Đ', 'D'), 'ø', 'o'), 'Ø', 'O') AS title, replace(replace(replace(replace(replace(replace(r.body_markdown, 'ł', 'l'), 'Ł', 'L'), 'đ', 'd'), 'Đ', 'D'), 'ø', 'o'), 'Ø', 'O') AS body
                        FROM note_doc d JOIN note_revision r ON r.id = d.head_revision_id
                        WHERE r.state = 'applied'
        """

    @Test func theViewSQLIsFrozen() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        let sql = try store.read { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'note_fts_source'")
        }
        // Whitespace is layout only; every letter of the folding is compared.
        func squeezed(_ text: String?) -> String? {
            text?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        #expect(squeezed(sql) == squeezed(Self.frozenViewSQL))
    }

    @Test func theFrozenSQLFoldsExactlyThePairsAndNothingElse() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        let sample = "żółć Łódź đorđe Đ bjørn Ø straße ñ é ß"
        let sqlFolded = try store.read { db in
            try String.fetchOne(
                db, sql: "SELECT \(NotesFullTextFolding.frozenSQL("?"))", arguments: [sample])
        }
        #expect(sqlFolded == NotesFullTextFolding.fold(sample))
        #expect(NotesFullTextFolding.pairs.map(\.from) == ["ł", "Ł", "đ", "Đ", "ø", "Ø"])
        #expect(NotesFullTextFolding.fold("ł Ł đ Đ ø Ø") == "l L d D o O")
        // Not over-folded: `TextNormalizer` would turn ß into ss; the index does not.
        #expect(NotesFullTextFolding.fold("strasse") == "strasse")
        #expect(NotesFullTextFolding.fold("Straße") == "Straße")
    }

    @Test func searchFindsTheFoldedLettersAndDoesNotOverFold() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        try store.insertDocument(.manual("a", body: "Żółć w Łodzi"))
        try store.insertDocument(.manual("b", body: "Dorđe i Bjørn"))
        try store.insertDocument(.manual("c", body: "Strasse"))
        try store.insertDocument(.manual("d", body: "Straße"))
        #expect(try store.search("zolc").map(\.key.id) == ["a"])
        #expect(try store.search("lodzi").map(\.key.id) == ["a"])
        #expect(try store.search("ŁÓDZI").map(\.key.id) == ["a"])
        #expect(try store.search("dorde").map(\.key.id) == ["b"])
        #expect(try store.search("bjorn").map(\.key.id) == ["b"])
        #expect(try store.search("strasse").map(\.key.id) == ["c"])
    }

    @Test func theIndexRowIdIsTheDocumentId() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        _ = try store.insertDocument(.manual("a", body: "alpha"))
        let doc = try store.insertDocument(.manual("b", body: "beta"))
        let rowid = try store.read { db in
            try Int64.fetchOne(db, sql: "SELECT rowid FROM note_fts WHERE note_fts MATCH 'beta'")
        }
        #expect(rowid == doc.docID)
        #expect(try store.search("beta").map(\.docID) == [doc.docID])
    }

    @Test func onlyTheHeadOfAnAppliedRevisionIsIndexed() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        let doc = try store.insertDocument(.manual("a", body: "first words"))
        #expect(try store.search("first").count == 1)

        // A proposal, even a later one, is not the head and not indexed.
        try store.appendRevision(
            NewNoteRevision(
                docID: doc.docID, author: "agent", state: .proposed, body: "proposed words", now: Date(),
                expectedHeadID: nil))
        #expect(try store.search("proposed").isEmpty)
        #expect(try store.search("first").count == 1)

        // A head move re-indexes in the same transaction.
        try store.appendRevision(
            NewNoteRevision(
                docID: doc.docID, author: "human", state: .applied, body: "second words", now: Date(),
                expectedHeadID: doc.revisionID))
        #expect(try store.search("first").isEmpty)
        #expect(try store.search("second").count == 1)

        // An amend of the head re-indexes too.
        try store.write { db in
            try db.execute(
                sql:
                    "UPDATE note_revision SET body_markdown = 'amended words' WHERE id = (SELECT head_revision_id FROM note_doc)"
            )
        }
        #expect(try store.search("second").isEmpty)
        #expect(try store.search("amended").count == 1)

        // A head that is no longer applied leaves the index.
        try store.write { db in
            try db.execute(
                sql: "UPDATE note_revision SET state = 'discarded' WHERE id = (SELECT head_revision_id FROM note_doc)")
        }
        #expect(try store.search("amended").isEmpty)
    }

    @Test func aTitleMatchIsReportedAndDoesNotNeedABodyMatch() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        try store.insertDocument(.manual("a", body: "nothing here", title: "Budget plan"))
        try store.insertDocument(.manual("b", body: "the budget is tight"))
        let hits = try store.search("budget")
        #expect(Set(hits.map(\.key.id)) == ["a", "b"])
        #expect(hits.first { $0.key.id == "a" }?.titleMatched == true)
        #expect(hits.first { $0.key.id == "b" }?.titleMatched == false)
        #expect(hits.first { $0.key.id == "b" }?.snippet.contains("budget") == true)
        #expect(try store.search("   ").isEmpty)
        #expect(try store.search("\"*").isEmpty)
    }

    // MARK: Merge

    private func summary(_ id: String, matches: [String], title: Bool = false) -> NoteSummary {
        NoteSummary(
            id: NoteKey(pluginID: "meetings", id: id), kind: .meeting, title: nil,
            startedAt: Date(timeIntervalSince1970: 1), state: .ready,
            matches: matches.map { NoteLayerMatch(layerID: $0, snippet: "source \($0)") }, titleMatched: title)
    }

    @Test func sourceMatchesOnALayerWithALiveOverlayAreDroppedAndOnlyTheIndexDecides() {
        let key = NoteKey(pluginID: "meetings", id: "m1")
        let merged = NotesSearchMerge.merge(
            sourceHits: [summary("m1", matches: ["notes", "transcript"])],
            liveOverlayLayers: [key: ["notes"]], ftsHits: [])
        #expect(merged.count == 1)
        #expect(merged[0].matches.map(\.layerID) == ["transcript"])

        // Nothing left and no title match: the hit is dropped (a deleted word never matches through the source).
        let dropped = NotesSearchMerge.merge(
            sourceHits: [summary("m1", matches: ["notes"])], liveOverlayLayers: [key: ["notes"]], ftsHits: [])
        #expect(dropped.isEmpty)

        // The title matching keeps the hit with no layer matches.
        let titled = NotesSearchMerge.merge(
            sourceHits: [summary("m1", matches: ["notes"], title: true)], liveOverlayLayers: [key: ["notes"]],
            ftsHits: [])
        #expect(titled.count == 1)
        #expect(titled[0].matches.isEmpty)
        #expect(titled[0].titleMatched)
    }

    @Test func aLiveOverlayHitJoinsTheLiveNoteAndADetachedOneIsAlwaysItsOwnResult() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        // The live note's notes layer is overlaid; an earlier recording with the same key is detached.
        try store.insertDocument(.overlay("m1", layer: "notes", body: "kiwi live", author: "human", startedAtMs: 2_000))
        try store.insertDocument(
            .overlay(
                "m1", layer: "notes", body: "kiwi old notes", author: "human", startedAtMs: 1_000, state: .detached))
        try store.insertDocument(
            .overlay(
                "m1", layer: "transcript", body: "kiwi old transcript", author: "human", startedAtMs: 1_000,
                state: .detached))
        let key = NoteKey(pluginID: "meetings", id: "m1")
        let hits = try store.search("kiwi")
        #expect(hits.count == 3)

        let merged = NotesSearchMerge.merge(
            sourceHits: [summary("m1", matches: ["transcript"])], liveOverlayLayers: [key: ["notes"]], ftsHits: hits)
        let live = try #require(merged.first { $0.id == .live(key) })
        #expect(Set(live.matches.map(\.layerID)) == ["transcript", "notes"])
        let detached = try #require(merged.first { $0.id == .detached(key, startedAtMs: 1_000) })
        #expect(merged.count == 2)
        // One result for the detached item, with every matched layer.
        #expect(Set(detached.matches.map(\.layerID)) == ["notes", "transcript"])
        #expect(detached.id != live.id)
    }
}
