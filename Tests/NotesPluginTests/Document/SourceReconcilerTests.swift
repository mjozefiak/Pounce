import Foundation
import GRDB
import LintelKit
import Testing

@testable import NotesPlugin

extension RevisionWriter.Reconciliation {
    var tag: String {
        switch self {
        case .unchanged: "unchanged"
        case .versionOnly: "versionOnly"
        case .applied: "applied"
        case .proposed: "proposed"
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SourceReconcilerTests {
    private func tags(_ result: SourceReconciler.OpenResult) -> [String: String]? {
        guard case .reconciled(let map) = result else { return nil }
        return map.mapValues(\.tag)
    }

    // MARK: Per layer

    @Test func eachLayerIsComparedByItsOwnVersion() async throws {
        let r = try ReconRig()
        let notes = r.rig.layer("old notes", id: "notes", version: "n1")
        let transcript = r.rig.layer("hello", id: "transcript", version: "t1", author: .stt)
        try await r.editedOverlay(notes)
        let transcriptDoc = try await r.editedOverlay(transcript)
        let before = try r.store.revisions(of: transcriptDoc.id).count
        // Notes were regenerated; the transcript did not change.
        r.publish([r.rig.layer("regenerated notes", id: "notes", version: "n2"), transcript])
        let result = await r.reconciler.reconcile(r.key)
        #expect(tags(result) == ["notes": "proposed", "transcript": "unchanged"])
        #expect(try r.store.revisions(of: transcriptDoc.id).count == before)  // no transcript revision or proposal
    }

    @Test func aTranscriptChangeNeverTouchesAnEditedNotesLayer() async throws {
        let r = try ReconRig()
        let notes = r.rig.layer("notes", id: "notes", version: "n1")
        let transcript = r.rig.layer("hello", id: "transcript", version: "t1", author: .stt)
        let notesDoc = try await r.editedOverlay(notes)
        try r.rig.seededDocument(transcript)
        let before = try r.store.revisions(of: notesDoc.id).count
        r.publish([notes, r.rig.layer("hello and more", id: "transcript", version: "t2", author: .stt)])
        #expect(tags(await r.reconciler.reconcile(r.key)) == ["notes": "unchanged", "transcript": "applied"])
        #expect(try r.store.revisions(of: notesDoc.id).count == before)
    }

    @Test func aLayerWithoutAnOverlayCreatesNothing() async throws {
        let r = try ReconRig()
        try r.rig.seededDocument(r.rig.layer("hello", id: "transcript", version: "t1", author: .stt))
        r.publish([
            r.rig.layer("notes arrive later", id: "notes", version: "n1"),
            r.rig.layer("hello", id: "transcript", version: "t1", author: .stt),
        ])
        #expect(tags(await r.reconciler.reconcile(r.key)) == ["transcript": "unchanged"])
        #expect(try r.store.liveDocuments(key: r.key).map(\.layer) == ["transcript"])
    }

    // MARK: The reconciliation rule

    @Test func withoutUserWritingTheSourceRevisionIsAppliedAsTheLayersAuthor() async throws {
        let r = try ReconRig()
        let notes = try r.rig.seededDocument(r.rig.layer("old", id: "notes", version: "n1"))
        let transcript = try r.rig.seededDocument(r.rig.layer("old", id: "transcript", version: "t1", author: .stt))
        r.publish([
            r.rig.layer("new notes", id: "notes", version: "n2"),
            r.rig.layer("new transcript", id: "transcript", version: "t2", author: .stt),
        ])
        #expect(tags(await r.reconciler.reconcile(r.key)) == ["notes": "applied", "transcript": "applied"])
        let notesHead = try r.rig.head(notes.id)
        #expect(notesHead.author == "agent")
        #expect(notesHead.body == "new notes")
        #expect(try r.rig.head(transcript.id).author == "stt")
        #expect(try r.store.document(id: notes.id)?.sourceVersionSeen == "n2")  // same transaction as the revision
        // A second look at the same version does nothing.
        #expect(tags(await r.reconciler.reconcile(r.key)) == ["notes": "unchanged", "transcript": "unchanged"])
    }

    @Test func withUserWritingTheSourceRevisionIsAPendingProposalAndNeverSilent() async throws {
        let r = try ReconRig()
        let doc = try await r.editedOverlay(r.rig.layer("old", version: "n1"), text: "my edit")
        r.publish([r.rig.layer("regenerated", version: "n2")])
        #expect(tags(await r.reconciler.reconcile(r.key)) == ["notes": "proposed"])
        #expect(try r.rig.head(doc.id).body == "my edit")
        let pending = try r.store.revisions(of: doc.id).last
        #expect(pending?.state == .proposed)
        #expect(pending?.author == "agent")
        #expect(pending?.body == "regenerated")
        #expect(try r.store.document(id: doc.id)?.sourceVersionSeen == "n2")
        // The proposal is never auto-discarded and not repeated for the same version.
        #expect(tags(await r.reconciler.reconcile(r.key)) == ["notes": "unchanged"])
        #expect(try r.store.revisions(of: doc.id).filter { $0.state == .proposed }.count == 1)
    }

    @Test func aNewTextEqualToTheHeadOnlyUpdatesTheVersion() async throws {
        let r = try ReconRig()
        let doc = try r.rig.seededDocument(r.rig.layer("same text", version: "n1"))
        r.publish([r.rig.layer("same text", version: "n2")])
        #expect(tags(await r.reconciler.reconcile(r.key)) == ["notes": "versionOnly"])
        #expect(try r.store.revisions(of: doc.id).count == 1)
        #expect(try r.store.document(id: doc.id)?.sourceVersionSeen == "n2")
    }

    @Test func aSpeakerRenameOrASecondSpeakerPlanChangesNothingInAnEditedTranscript() async throws {
        let r = try ReconRig()
        let speakers = [NoteSpeaker(id: "s1", name: "Speaker 1")]
        let transcript = r.rig.layer("one\n\ntwo", id: "transcript", version: "t1", author: .stt)
        let doc = try await r.editedOverlay(transcript, text: "one\n\ntwo edited")
        let before = try r.store.revisions(of: doc.id).count
        // The rename and the second `applySpeakerPlan` leave the layer's version alone (speakers are not in it).
        r.publish([transcript], speakers: [NoteSpeaker(id: "s9", name: "Ala")])
        #expect(tags(await r.reconciler.reconcile(r.key)) == ["transcript": "unchanged"])
        #expect(try r.store.revisions(of: doc.id).count == before)  // no proposal
        // The overlay shows the source's CURRENT speakers; the seed's snapshot is only a fallback.
        let heads = try NoteOverlayContent.heads(for: .live(r.key), in: r.store)
        let content = try #require(r.source.contents[r.key])
        let shown = try #require(
            NoteOverlayContent.compose(item: .live(r.key), source: content, heads: heads, summary: nil))
        #expect(shown.speakers.map(\.name) == ["Ala"])
        #expect(shown.layers.first?.markdown == "one\n\ntwo edited")
        _ = speakers
    }

    // MARK: Unknown is not gone

    @Test func anyThrowFromASourceIsUnavailableAndDetachesNothing() async throws {
        let r = try ReconRig()
        let doc = try await r.editedOverlay(r.rig.layer("old", version: "n1"))
        r.publish([r.rig.layer("new", version: "n2")])
        r.source.contentBehavior = .throwsError
        #expect(await r.reconciler.reconcile(r.key) == .unavailable)
        #expect(try r.store.document(id: doc.id)?.sourceState == .present)
        r.box.sources = []  // the plugin is off
        #expect(await r.reconciler.reconcile(r.key) == .unavailable)
        #expect(try r.store.document(id: doc.id)?.sourceState == .present)
    }

    @Test func aNoteThatIsGoneDetachesItsOverlaysAndKeepsTheKeptOnes() async throws {
        let r = try ReconRig()
        let kept = try await r.editedOverlay(r.rig.layer("old", version: "n1"))
        let unkept = try r.rig.seededDocument(
            r.rig.layer("old transcript", id: "transcript", version: "t1", author: .stt))
        r.source.contents[r.key] = nil  // the store is open and has no such note
        #expect(await r.reconciler.reconcile(r.key) == .detached)
        #expect(try r.store.document(id: kept.id)?.sourceState == .detached)
        #expect(try r.store.document(id: unkept.id) == nil)  // detach means delete without user writing
    }

    @Test func aStartTimeThatDiffersDetachesBeforeAnySeedOrWriteAndRoundsToMilliseconds() async throws {
        let r = try ReconRig()
        let doc = try await r.editedOverlay(r.rig.layer("old", version: "n1"))
        // A sub-millisecond fraction round-trips without detaching.
        r.publish([r.rig.layer("old", version: "n1")], startedAt: r.rig.started.addingTimeInterval(0.0004))
        #expect(tags(await r.reconciler.reconcile(r.key)) == ["notes": "unchanged"])
        #expect(try r.store.document(id: doc.id)?.sourceState == .present)
        // Another millisecond is another recording.
        r.publish([r.rig.layer("old", version: "n1")], startedAt: r.rig.started.addingTimeInterval(0.002))
        #expect(await r.reconciler.reconcile(r.key) == .detached)
        #expect(try r.store.document(id: doc.id)?.sourceState == .detached)
        #expect(try r.store.liveDocument(key: r.key, layer: "notes") == nil)
    }

    // MARK: Open documents only

    @Test func aThousandOverlaysAndFiftyChangeEventsReadOnlyTheOpenDocuments() async throws {
        let r = try ReconRig()
        try r.store.write { db in
            for index in 0..<1000 {
                _ = try NotesStore.insertDocument(.overlay("bulk\(index)"), in: db)
            }
        }
        let second = NoteKey(pluginID: "meetings", id: "m2")
        for key in [r.key, second] {
            let layer = r.rig.layer("text", version: "v1")
            let doc = try r.rig.seededDocument(layer, key: key)
            _ = r.registry.writer(for: .live(key, layer: "notes"), item: .live(key)) {
                r.rig.writer(.existing(docID: doc.id))
            }
            r.publish([layer], key: key)
        }
        for _ in 0..<50 { await r.reconciler.reconcileOpenDocuments() }
        #expect(r.source.contentCalls == 100)  // two open notes, fifty events; never one per overlay
    }

    // MARK: The sweep

    private func insertKeys(_ r: ReconRig, count: Int, author: String = "human") throws -> [NoteKey] {
        try r.store.write { db in
            for index in 0..<count {
                _ = try NotesStore.insertDocument(.overlay("k\(index)", author: author), in: db)
            }
        }
        return (0..<count).map { NoteKey(pluginID: "meetings", id: "k\($0)") }
    }

    @Test func theSweepDetachesWhatAnOpenSourceOmitsAndNothingElse() async throws {
        let r = try ReconRig()
        let keys = try insertKeys(r, count: 3)
        r.source.existing = [keys[0], keys[2]]
        #expect(await r.reconciler.sweep() == [keys[1]])
        let detached = try r.store.detachedOverlays()
        #expect(detached.map(\.key) == [keys[1]])
        #expect(try r.store.liveOverlayKeys() == [keys[0], keys[2]])
    }

    @Test func aThrowOrAnInactiveSourceDetachesNothing() async throws {
        let r = try ReconRig()
        _ = try insertKeys(r, count: 3)
        r.source.existing = []
        r.source.existsBehavior = .throwsError
        #expect(await r.reconciler.sweep().isEmpty)
        #expect(try r.store.detachedOverlays().isEmpty)
        r.source.existsBehavior = .answers
        r.box.sources = []
        await r.library.refreshSources()
        #expect(await r.reconciler.sweep().isEmpty)
        #expect(try r.store.detachedOverlays().isEmpty)
    }

    @Test func theSweepAsksInBatchesOfFiveHundred() async throws {
        let r = try ReconRig()
        _ = try insertKeys(r, count: 1200)
        await r.reconciler.sweep()
        #expect(r.source.existsCalls.map(\.count) == [500, 500, 200])
    }

    @Test func theSweepDeletesLeftoverUnkeptDetachedRowsThatAreNotOpen() async throws {
        let r = try ReconRig()
        let leftover = try r.store.insertDocument(.overlay("old", author: "agent", state: .detached))
        let keptLeftover = try r.store.insertDocument(.overlay("older", author: "human", state: .detached))
        await r.reconciler.sweep()
        #expect(try r.store.document(id: leftover.docID) == nil)
        #expect(try r.store.document(id: keptLeftover.docID) != nil)
    }

    @Test func theSweepRunsOnActivationThenEveryTenMinutesOnTheInjectedClock() async throws {
        let r = try ReconRig()
        _ = try insertKeys(r, count: 2)
        let task = Task { await r.reconciler.runSweeps() }
        await r.source.waitForExistsStarts(1)
        // The fan-out's own deadline sleeps once; the sweeper's sleep is the second.
        await r.rig.clock.waitForSleeps(2)
        r.rig.clock.advance(by: .seconds(599))
        #expect(r.source.existsCalls.count == 1)
        r.rig.clock.advance(by: .seconds(1))
        await r.source.waitForExistsStarts(2)
        task.cancel()
        await task.value
    }
}
