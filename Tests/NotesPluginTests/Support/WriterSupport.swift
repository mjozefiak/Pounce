import Foundation
import GRDB
import LintelKit
import Synchronization
import Testing

@testable import NotesPlugin

/// The rigs one test built, so the `.finishesRigs` trait can end them in the test's context. It holds them strongly: a
/// rig a writer's callback keeps alive (a reference cycle through the test body) is still finished.
final class RigCollector: Sendable {
    @TaskLocal static var current: RigCollector?
    private let rigs = Mutex<[DocRig]>([])

    func add(_ rig: DocRig) { rigs.withLock { $0.append(rig) } }
    func take() -> [DocRig] {
        rigs.withLock {
            defer { $0 = [] }
            return $0
        }
    }
}

/// Ends the rigs a test built once its body returns or throws: writers discarded, clock finished, and a test that left
/// a timer asleep fails at the line that built its rig. Put it on every suite that builds a `DocRig`.
struct FinishesRigs: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        guard testCase != nil else { return try await function() }
        let collector = RigCollector()
        let result = await Result { try await RigCollector.$current.withValue(collector) { try await function() } }
        await MainActor.run { for rig in collector.take().reversed() { rig.finish() } }
        try result.get()
    }
}

extension Trait where Self == FinishesRigs {
    static var finishesRigs: Self { FinishesRigs() }
}

/// A temporary store, an injected clock and the counters a writer test waits on (no sleeping, no yielding).
@MainActor
final class DocRig {
    let harness: NotesHarness
    let store: NotesStore
    let clock = ManualClock()
    let wrote = CountLatch()
    let idleClosed = CountLatch()
    let saveFailures = CountLatch()
    let saveRecoveries = CountLatch()
    let meeting = NoteKey(pluginID: "meetings", id: "m1")
    let started = Date(timeIntervalSince1970: 1_800_000_000)
    private var writers: [RevisionWriter] = []
    private var cleanups: [() -> Void] = []
    private let origin: SourceLocation

    init(readOnly: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) throws {
        origin = sourceLocation
        harness = try NotesHarness()
        if readOnly { harness.settingsStore.setValue(.bool(true), forKey: "plugins.notes.readOnly") }
        store = try harness.openStore()
        if let collector = RigCollector.current {
            collector.add(self)
        } else {
            Issue.record(
                "A DocRig needs the .finishesRigs trait on its suite, which ends its clock.",
                sourceLocation: sourceLocation)
        }
    }

    var log: RecordingNotesLog { harness.log }

    /// The end of the test, called by the `.finishesRigs` trait inside the test's own context (a `deinit` has none, so
    /// an issue recorded there is lost or filed under no test). Every writer this rig made is discarded (its debounce,
    /// idle and retry tasks are cancelled), then the clock ends. A sleeper still on the clock after that belongs to a
    /// timer nobody stopped: the test fails at the line that built the rig instead of leaving a task asleep until the
    /// process exits.
    func finish() {
        for writer in writers { writer.discardPending() }
        for cleanup in cleanups { cleanup() }
        let left = clock.finish()
        writers = []
        cleanups = []
        if left > 0 {
            Issue.record(
                "\(left) timer task(s) were still sleeping on the ManualClock when the test ended. Stop the writer with closeSession() or discardPending() before the test ends.",
                sourceLocation: origin)
        }
    }

    /// Work `finish()` runs before it ends the clock, for writers the rig does not make itself (a registry's).
    func onFinish(_ cleanup: @escaping () -> Void) { cleanups.append(cleanup) }

    func writer(
        _ target: RevisionWriter.Target, timing: RevisionWriter.Timing = .init(), registry: NoteDocumentRegistry? = nil,
        sourceStartedAtMs: (@Sendable () async -> Int64?)? = nil,
        onWrote: @escaping @Sendable (RevisionWriter.Outcome) -> Void = { _ in }
    ) -> RevisionWriter {
        let writer = RevisionWriter(
            store: store, target: target, clock: clock, timing: timing,
            observer: RevisionWriter.Observer(
                wrote: { [wrote] outcome in
                    wrote.increment()
                    onWrote(outcome)
                }, idleClosed: { [idleClosed] in idleClosed.increment() },
                saveFailed: { [saveFailures, saveRecoveries] failed in
                    if failed { saveFailures.increment() } else { saveRecoveries.increment() }
                }),
            sourceStartedAtMs: sourceStartedAtMs, log: log)
        writers.append(writer)
        return writer
    }

    /// A writer a test built itself (a lazy store provider, say) on this rig's clock: the rig discards it at the end.
    @discardableResult
    func adopt(_ writer: RevisionWriter) -> RevisionWriter {
        writers.append(writer)
        return writer
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
        // The registry's writers are discarded before the rig's clock ends.
        rig.onFinish { [registry] in registry.discardAll() }
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
