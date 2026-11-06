import Foundation
import GRDB
import LintelKit
import Testing

@testable import NotesPlugin

/// A temporary store, an injected clock and the counters a writer test waits on (no sleeping, no yielding).
@MainActor
final class DocRig {
    let harness: NotesHarness
    let store: NotesStore
    let clock = ManualClock()
    let wrote = CountLatch()
    let idleClosed = CountLatch()
    let meeting = NoteKey(pluginID: "meetings", id: "m1")
    let started = Date(timeIntervalSince1970: 1_800_000_000)

    init(readOnly: Bool = false) throws {
        harness = try NotesHarness()
        if readOnly { harness.settingsStore.setValue(.bool(true), forKey: "plugins.notes.readOnly") }
        store = try harness.openStore()
    }

    var log: RecordingNotesLog { harness.log }

    func writer(
        _ target: RevisionWriter.Target, timing: RevisionWriter.Timing = .init(), registry: NoteDocumentRegistry? = nil
    ) -> RevisionWriter {
        RevisionWriter(
            store: store, target: target, clock: clock, timing: timing,
            observer: RevisionWriter.Observer(
                wrote: { [wrote] _ in wrote.increment() }, idleClosed: { [idleClosed] in idleClosed.increment() }),
            log: log)
    }

    func layer(
        _ text: String, id: String = "notes", version: String = "v1", author: NoteAuthor = .agent,
        provenance: [NoteBlockProvenance] = []
    ) -> NoteLayer {
        NoteLayer(id: id, author: author, markdown: text, provenance: provenance, version: version)
    }

    func content(
        key: NoteKey? = nil, layers: [NoteLayer], state: NoteState = .ready, startedAt: Date? = nil,
        speakers: [NoteSpeaker] = []
    ) -> NoteContent {
        NoteContent(
            summary: NoteSummary(
                id: key ?? meeting, kind: .meeting, title: "t", startedAt: startedAt ?? started, state: state),
            layers: layers, speakers: speakers)
    }

    func plan(
        _ layer: NoteLayer, key: NoteKey? = nil, startedAt: Date? = nil, speakers: [NoteSpeaker] = []
    ) throws -> SeedPlan {
        try #require(
            OverlaySeeder.plan(
                content: content(key: key, layers: [layer], startedAt: startedAt, speakers: speakers), layerID: layer.id
            ))
    }

    /// An overlay seeded the way a first edit does, plus its `RevisionWriter`.
    @discardableResult
    func seededDocument(_ layer: NoteLayer, key: NoteKey? = nil, startedAt: Date? = nil) throws -> DocumentRecord {
        try OverlaySeeder.seed(
            plan(layer, key: key, startedAt: startedAt), in: store, now: Date(timeIntervalSince1970: 100))
    }

    func humanRevisions(_ docID: Int64) throws -> [RevisionRecord] {
        try store.revisions(of: docID).filter { $0.author == "human" && $0.state == .applied }
    }

    func head(_ docID: Int64) throws -> RevisionRecord {
        try #require(try store.headRevision(of: docID))
    }

    /// Makes the next insert of a revision with this body fail, the way a full disk or a crash would.
    func failNextInsert(body: String) throws {
        try store.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER fault_inject BEFORE INSERT ON note_revision WHEN new.body_markdown = '\(body)'
                    BEGIN SELECT RAISE(ABORT, 'injected'); END
                    """)
        }
    }

    func clearFault() throws {
        try store.write { db in try db.execute(sql: "DROP TRIGGER IF EXISTS fault_inject") }
    }

    func addComment(doc: Int64, anchorRevision: Int64, status: String = "open") throws {
        try store.write { db in
            try db.execute(
                sql: """
                    INSERT INTO note_comment (doc_id, thread_id, author, created_at, body, anchor_revision_id,
                        anchor_start, anchor_end, anchor_block_hash, anchor_quote, status)
                    VALUES (?, 1, 'human', 1, 'c', ?, 0, 1, 'h', 'q', ?)
                    """, arguments: [doc, anchorRevision, status])
        }
    }
}

extension RevisionWriter.Outcome {
    var revisionID: Int64? {
        switch self {
        case .nothing: nil
        case .seeded(_, let id), .amended(let id), .appended(let id), .keptAsProposal(let id): id
        }
    }
}

/// A store, a registry, a library over both and one scripted `meetings` source: everything the reconciler and the
/// detacher touch, with no window and no real source.
@MainActor
final class ReconRig {
    let rig: DocRig
    let source = ScriptedNoteSource("meetings")
    let box: SourceBox
    let registry: NoteDocumentRegistry
    let library: NoteLibrary
    let reconciler: SourceReconciler
    let detacher: RegistryOverlayDetacher

    var store: NotesStore { rig.store }
    var key: NoteKey { rig.meeting }

    init() throws {
        rig = try DocRig()
        box = SourceBox([source])
        registry = NoteDocumentRegistry(log: rig.log)
        detacher = RegistryOverlayDetacher(store: rig.store, registry: registry)
        library = NoteLibrary(
            sources: { [box] in box.sources }, overlays: StoreOverlayIndex(store: rig.store), detacher: detacher,
            clock: rig.clock)
        reconciler = SourceReconciler(
            store: rig.store, library: library, detacher: detacher, registry: registry, clock: rig.clock, log: rig.log)
        let store = rig.store
        registry.cleanup = { open in _ = try? store.deleteUnkeptDetached(excluding: open) }
    }

    /// What the source returns for the note from now on.
    func publish(
        _ layers: [NoteLayer], key: NoteKey? = nil, startedAt: Date? = nil, state: NoteState = .ready,
        speakers: [NoteSpeaker] = []
    ) {
        let content = rig.content(key: key, layers: layers, state: state, startedAt: startedAt, speakers: speakers)
        source.contents[content.summary.id] = content
        var items = source.items.filter { $0.id != content.summary.id }
        items.append(content.summary)
        source.items = items
    }

    /// An overlay with an edit session on top: user writing.
    @discardableResult
    func editedOverlay(_ layer: NoteLayer, key: NoteKey? = nil, text: String = "edited") async throws -> DocumentRecord
    {
        let seed = try rig.seededDocument(layer, key: key)
        let writer = rig.writer(.existing(docID: seed.id))
        writer.submit(text)
        try await writer.flush(closingSession: true)
        return seed
    }
}
