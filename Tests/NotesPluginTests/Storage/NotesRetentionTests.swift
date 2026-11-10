import Foundation
import GRDB
import LintelKit
import Testing

@testable import NotesPlugin

/// Spec step 4.7, Retention: the leftover detached rows go on store open and in each sweep, and a `VACUUM` follows
/// at most once a day. (Detach means delete for an overlay without user writing or an open comment: `OverlayDetachTests`.)
@MainActor
@Suite(.timeLimit(.minutes(1))) struct NotesRetentionTests {
    private let day = NotesStore.vacuumInterval
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func vacuumRunsAtMostOncePerDay() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        #expect(store.vacuumIfDue(now: start))
        #expect(!store.vacuumIfDue(now: start.addingTimeInterval(day - 1)))
        #expect(store.vacuumIfDue(now: start.addingTimeInterval(day)))
        #expect(store.lastVacuum.withLock { $0 } == start.addingTimeInterval(day))
    }

    @Test func aFailedVacuumGivesTheDayBack() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        harness.settingsStore.setValue(.bool(true), forKey: "plugins.notes.readOnly")  // vacuum is a write
        let store = try harness.openStore()
        #expect(!store.vacuumIfDue(now: start))
        #expect(store.lastVacuum.withLock { $0 } == nil)
    }

    @Test func retentionDeletesLeftoverRowsAndVacuumsOnlyAfterADelete() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        #expect(try store.applyRetention(now: start) == 0)
        #expect(store.lastVacuum.withLock { $0 } == nil)  // nothing deleted, nothing vacuumed
        try store.insertDocument(.overlay("a", state: .detached))
        #expect(try store.applyRetention(now: start) == 1)
        #expect(store.lastVacuum.withLock { $0 } == start)
        try store.insertDocument(.overlay("b", state: .detached))
        #expect(try store.applyRetention(now: start.addingTimeInterval(60)) == 1)
        #expect(store.lastVacuum.withLock { $0 } == start)  // deleted again, but vacuumed less than a day ago
    }

    @Test func aKeptDetachedRowAndAnOpenOneSurvive() throws {
        let harness = try NotesHarness()
        defer { withExtendedLifetime(harness) {} }
        let store = try harness.openStore()
        let edited = try store.insertDocument(.overlay("c", author: "human", state: .detached))
        let open = try store.insertDocument(.overlay("d", state: .detached))
        let commented = try store.insertDocument(.overlay("e", state: .detached))
        try store.write { db in
            try db.execute(
                sql: """
                    INSERT INTO note_comment (doc_id, thread_id, author, created_at, body, anchor_revision_id,
                        anchor_start, anchor_end, anchor_block_hash, anchor_quote, status)
                    VALUES (?, 1, 'human', 1, 'c', ?, 0, 1, 'h', 'q', 'open')
                    """, arguments: [commented.docID, commented.revisionID])
        }
        #expect(try store.applyRetention(excluding: [open.docID], now: start) == 0)
        let ids = try store.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM note_doc ORDER BY id") }
        #expect(ids == [edited.docID, open.docID, commented.docID])
    }

    @Test func storeOpenDeletesTheLeftoverFromAnEarlierRun() throws {
        let harness = try NotesHarness()
        let first = harness.opener(now: { Date(timeIntervalSince1970: 1_800_000_000) })
        first.open()
        let store = try #require(first.store)
        let leftover = try store.insertDocument(.overlay("a", state: .detached))
        let kept = try store.insertDocument(.overlay("b", author: "human", state: .detached))
        let live = try store.insertDocument(.overlay("c"))
        first.close()

        let second = harness.opener()
        second.open()
        let ids = try #require(second.store).read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM note_doc ORDER BY id")
        }
        #expect(ids == [kept.docID, live.docID])
        #expect(!ids.contains(leftover.docID))
    }

    @Test func eachSweepDeletesLeftoverRowsButNotOpenOrKeptOnes() async throws {
        let rig = try ReconRig()
        let leftover = try rig.store.insertDocument(.overlay("x", state: .detached))
        let kept = try rig.store.insertDocument(.overlay("y", author: "human", state: .detached))
        await rig.reconciler.sweep()
        let ids = try rig.store.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM note_doc ORDER BY id") }
        #expect(ids == [kept.docID])
        #expect(!ids.contains(leftover.docID))
        #expect(rig.store.lastVacuum.withLock { $0 } != nil)
    }
}
