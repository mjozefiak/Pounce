import Foundation
import LintelCore
import LintelKit
import Synchronization

/// The one writer of one layer document (spec "Saving", "One writer"). Every head-moving write for a
/// `NoteDocumentID` goes through it: autosave, Restore, Apply, a Revise result and the source reconciler.
///
/// - The editor hands every change to `submit`, which only stores the buffer and (re)starts a 1 s timer on the
///   INJECTED clock; the timer, a blur, a tab close, a mode switch, a window close, `deactivate()` and any other
///   write call `flush`, which takes the buffer and writes it. Writes are serialised by an actor and run off the
///   main thread; a write older than one already applied is dropped.
/// - Writes in one edit session amend that session's `human` revision until it is referenced (a comment anchor,
///   `base_head_id`, `restored_from`). A comment, Revise, Apply, Restore and a reconciliation close the session
///   (`flush(closingSession:)`); one also closes after the idle time (5 min, on the injected clock).
/// - The first write of an overlay inserts the seed (the layer as rendered, with its version) and the first
///   `human` revision in ONE transaction.
/// - A compare-and-set loss is a defect path: the human text is stored as a `proposed` revision (never discarded,
///   never applied), `casConflict` is logged and the outcome says so.
/// - With `plugins.notes.readOnly` (or a newer schema) the store refuses and no revision is ever written; the
///   buffer is kept so a later retry can save it.
///
/// Note, transcript and dictated text never reach a log; only codes, counts and the hashed key do.
final class RevisionWriter: Sendable {
    struct Timing: Sendable {
        /// Typing is written at most this long after the last keystroke.
        var debounce: Duration = .seconds(1)
        /// A history granularity: a new `human` revision starts after this much idle time.
        var sessionIdle: Duration = .seconds(300)
        /// Typing is written at most this long after the FIRST unsaved keystroke, however long the user keeps typing.
        var maxWait: Duration = .seconds(5)
        /// A failed write is retried after this long, doubling up to `retryMax`.
        var retryInitial: Duration = .seconds(2)
        var retryMax: Duration = .seconds(60)
    }

    /// Hooks for tests and the UI: a buffered write finished, the idle timer closed the session.
    struct Observer: Sendable {
        var wrote: @Sendable (Outcome) -> Void = { _ in }
        var idleClosed: @Sendable () -> Void = {}
        /// The save state changed: `true` after a write failed (the text stays buffered and is retried with
        /// backoff), `false` once a write succeeded again.
        var saveFailed: @Sendable (Bool) -> Void = { _ in }
    }

    enum Target: Sendable {
        case existing(docID: Int64)
        /// No row yet: the first write seeds it from this plan.
        case seed(SeedPlan)
    }

    enum Outcome: Sendable, Equatable {
        case nothing
        case seeded(docID: Int64, revisionID: Int64)
        case amended(revisionID: Int64)
        case appended(revisionID: Int64)
        /// The head moved under the writer: the text was kept as a `proposed` revision.
        case keptAsProposal(revisionID: Int64)
    }

    enum Reconciliation: Sendable, Equatable {
        case unchanged
        /// The source's text equals the head's: only `source_version_seen` moved.
        case versionOnly
        /// No user writing: a revision authored as the layer's author was appended.
        case applied(revisionID: Int64)
        /// User writing: a `proposed` revision, the head unchanged.
        case proposed(revisionID: Int64)
    }

    /// The document a writer writes to, and its head revision.
    struct Head: Sendable, Equatable {
        var docID: Int64
        var revisionID: Int64
        var body: String
    }

    private struct Pending {
        var text: String?
        var serial = 0
        var debounce: Task<Void, Never>?
        var idle: Task<Void, Never>?
        var maxWait: Task<Void, Never>?
        var retry: Task<Void, Never>?
        var failed = false
        var retired = false
        var onSaveFailed: (@Sendable (Bool) -> Void)?
    }

    private let core: Core
    private let clock: any Clock<Duration>
    private let timing: Timing
    private let observer: Observer
    private let pending = Mutex(Pending())

    init(
        store: NotesStore, target: Target, clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { Date() }, timing: Timing = Timing(),
        observer: Observer = Observer(), sourceStartedAtMs: (@Sendable () async -> Int64?)? = nil,
        log: any NotesLogging = OSNotesLog()
    ) {
        self.clock = clock
        self.timing = timing
        self.observer = observer
        core = Core(
            store: store, provider: nil, target: target, now: now, sourceStartedAtMs: sourceStartedAtMs, log: log)
    }

    /// A writer that opens its store at the first write (`provider`, which answers `nil` when it cannot).
    init(
        storeProvider: @escaping @Sendable () async -> NotesStore?, target: Target,
        clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { Date() },
        timing: Timing = Timing(), observer: Observer = Observer(),
        sourceStartedAtMs: (@Sendable () async -> Int64?)? = nil, log: any NotesLogging = OSNotesLog()
    ) {
        self.clock = clock
        self.timing = timing
        self.observer = observer
        core = Core(
            store: nil, provider: storeProvider, target: target, now: now, sourceStartedAtMs: sourceStartedAtMs,
            log: log)
    }

    /// The store this writer writes to, opened if it was not yet (the first write or comment).
    func openedStore() async throws -> NotesStore { try await core.openStore() }

    /// `true` after a compare-and-set loss until a head-moving write (Restore, Apply) resolves it: while it holds,
    /// every typed write goes to a `proposed` revision and the head is never overwritten.
    var hasConflict: Bool { get async { await core.conflictProposalID != nil } }

    /// The row's id once it exists (a seed that was never written has none).
    var docID: Int64? { get async { await core.docID } }

    /// `true` while typed text waits for the next write.
    var hasPendingText: Bool { pending.withLock { $0.text != nil } }

    /// Stops a document whose recording was detached before it had a row: it can never seed (its snapshot belongs
    /// to a recording that is gone), so a later flush throws instead of writing against the wrong note.
    func retire() { pending.withLock { $0.retired = true } }

    /// The document is being deleted (the user confirmed it): the buffered text goes with it, no timer or retry
    /// writes it again, and the writer stays retired.
    func discardPending() {
        let tasks = pending.withLock { state -> [Task<Void, Never>?] in
            let all = [state.debounce, state.idle, state.maxWait, state.retry]
            state.text = nil
            state.debounce = nil
            state.idle = nil
            state.maxWait = nil
            state.retry = nil
            state.failed = false
            state.retired = true
            return all
        }
        for task in tasks { task?.cancel() }
    }

    // MARK: Typing

    /// The editor's whole buffer after a change. Synchronous: stores it and restarts the 1 s timer.
    func submit(_ text: String) {
        let timer = Task { [weak self, clock, debounce = timing.debounce] in
            do { try await clock.sleep(for: debounce) } catch { return }
            guard let self else { return }
            _ = try? await self.flush()
        }
        let old = pending.withLock { state -> Task<Void, Never>? in
            let old = state.debounce
            state.text = text
            state.serial += 1
            state.debounce = timer
            // The max-wait timer runs from the first unsaved keystroke and is not restarted by later ones.
            if state.maxWait == nil {
                state.maxWait = Task { [weak self, clock, maxWait = timing.maxWait] in
                    do { try await clock.sleep(for: maxWait) } catch { return }
                    guard let self else { return }
                    _ = try? await self.flush()
                }
            }
            return old
        }
        old?.cancel()
    }

    /// Writes what is buffered. `closingSession` ends the edit session afterwards (a comment, Revise, Apply,
    /// Restore, a reconciliation). A write that fails keeps the text for a retry.
    @discardableResult
    func flush(closingSession: Bool = false) async throws -> Outcome {
        let taken = pending.withLock { state -> (text: String, serial: Int)? in
            state.debounce?.cancel()
            state.debounce = nil
            state.maxWait?.cancel()
            state.maxWait = nil
            guard let text = state.text else { return nil }
            state.text = nil
            return (text, state.serial)
        }
        var outcome = Outcome.nothing
        if let taken {
            do {
                // A retired writer (its recording was detached before it had a row) cannot seed; the text is kept
                // and the failure reported, never dropped.
                if pending.withLock({ $0.retired }), await core.docID == nil {
                    throw NotesError.guardRejected(rule: "detached")
                }
                outcome = try await core.writeHuman(taken.text, serial: taken.serial)
                observer.wrote(outcome)
                reportSave(failed: false)
            } catch {
                pending.withLock { if $0.text == nil { $0.text = taken.text } }
                reportSave(failed: true)
                startRetry()
                throw error
            }
        }
        if closingSession {
            await core.closeSession()
            cancelIdleTimer()
        } else if outcome != .nothing {
            startIdleTimer()
        }
        return outcome
    }

    func closeSession() async {
        await core.closeSession()
        cancelIdleTimer()
    }

    // MARK: Save failures

    private func reportSave(failed: Bool) {
        let (changed, handler) = pending.withLock { state -> (Bool, (@Sendable (Bool) -> Void)?) in
            defer { state.failed = failed }
            return (state.failed != failed, state.onSaveFailed)
        }
        if changed {
            observer.saveFailed(failed)
            handler?(failed)
        }
    }

    /// `true` while the last write failed and its text is still buffered.
    var isSaveFailing: Bool { pending.withLock { $0.failed } }

    /// The UI's hook for the save state (the editing session); replaces an earlier one.
    func setSaveFailureHandler(_ handler: (@Sendable (Bool) -> Void)?) {
        pending.withLock { $0.onSaveFailed = handler }
    }

    /// Retries a failed write on the injected clock with doubling delays; ends when a write succeeds, nothing is
    /// buffered any more, or the writer is retired.
    private func startRetry() {
        let task = Task { [weak self, clock, timing] in
            var delay = timing.retryInitial
            while !Task.isCancelled {
                do { try await clock.sleep(for: delay) } catch { return }
                guard let self else { return }
                if self.pending.withLock({ $0.retired }) {
                    self.endRetry()
                    return
                }
                do {
                    try await self.flush()
                    self.endRetry()
                    return
                } catch {
                    delay = min(delay * 2, timing.retryMax)
                }
            }
        }
        let installed = pending.withLock { state -> Bool in
            guard state.retry == nil else { return false }
            state.retry = task
            return true
        }
        if !installed { task.cancel() }
    }

    private func endRetry() {
        pending.withLock { $0.retry = nil }
    }

    // MARK: Other head-moving writes

    /// Restore: a new applied `human` revision with the text and the authors of `revisionID`, recording
    /// `restored_from`. The buffer is flushed first.
    @discardableResult
    func restore(revisionID: Int64) async throws -> Int64 {
        try await flush(closingSession: true)
        return try await core.restore(revisionID)
    }

    /// An applied revision by `author` (a Revise result, an Apply). The buffer is flushed first; the head moves
    /// with compare-and-set.
    ///
    /// `expectingHead` is the head a run captured (`base_head_id`): when the head is another one, nothing is written
    /// and `casConflict` is thrown. Text typed since (a buffer that is not empty) is never overwritten either: the
    /// same error, and the buffer stays for its own write.
    @discardableResult
    func appendApplied(
        author: NoteAuthor, body: String, summary: String? = nil, metaJSON: String? = nil, expectingHead: Int64? = nil
    ) async throws -> Int64 {
        if expectingHead != nil, hasPendingText { throw NotesError.casConflict }
        try await flush(closingSession: true)
        return try await core.append(
            author: author.rawValue, body: body, summary: summary, metaJSON: metaJSON, state: .applied,
            expectingHead: expectingHead)
    }

    /// Apply: the proposal becomes an `applied` revision on top of `expectingHead`, the head the user compared it
    /// with. A moved head, or text typed since, is a `casConflict`: nothing is written and nothing typed is replaced.
    @discardableResult
    func applyProposal(id: Int64, expectingHead: Int64) async throws -> Int64 {
        if hasPendingText { throw NotesError.casConflict }
        try await flush(closingSession: true)
        return try await core.applyProposal(id, expectingHead: expectingHead)
    }

    /// Discard: the proposal is set aside for good (it stays in the store, hidden from History).
    func discardProposal(id: Int64, confirmedRemoval: Bool = false) async throws {
        try await flush(closingSession: true)
        try await core.discardProposal(id, confirmedRemoval: confirmedRemoval)
    }

    /// A `proposed` revision: never moves the head.
    @discardableResult
    func appendProposal(author: NoteAuthor, body: String, summary: String? = nil, metaJSON: String? = nil)
        async throws -> Int64
    {
        try await flush(closingSession: true)
        return try await core.append(
            author: author.rawValue, body: body, summary: summary, metaJSON: metaJSON, state: .proposed)
    }

    /// The document row and its head, creating the overlay first when the layer has none (a comment without
    /// editing seeds it, spec "Overlay model"). The buffer is flushed and the session closed first, so a comment's
    /// anchor revision is a revision that is never amended afterwards.
    func ensureDocument() async throws -> Head {
        try await flush(closingSession: true)
        return try await core.ensureDocument()
    }

    /// The source layer moved: compares `layer.version` with the document's `source_version_seen` (the SAME
    /// layer only). The buffer is flushed first, so a human revision exists before the choice between an
    /// `agent`/`stt` revision and a proposal.
    func reconcile(layer: NoteLayer) async throws -> Reconciliation {
        try await flush(closingSession: true)
        return try await core.reconcile(layer)
    }

    // MARK: Timers

    private func startIdleTimer() {
        let timer = Task { [weak self, clock, idle = timing.sessionIdle] in
            do { try await clock.sleep(for: idle) } catch { return }
            guard let self else { return }
            await self.core.closeSession()
            self.observer.idleClosed()
        }
        let old = pending.withLock { state -> Task<Void, Never>? in
            let old = state.idle
            state.idle = timer
            return old
        }
        old?.cancel()
    }

    private func cancelIdleTimer() {
        let old = pending.withLock { state -> Task<Void, Never>? in
            let old = state.idle
            state.idle = nil
            return old
        }
        old?.cancel()
    }

    // MARK: Core

    private actor Core {
        /// The store, resolved at the first write (lazy-store rule): a writer for a layer that was never edited
        /// holds only the provider, so opening an editor creates no Keychain item and no `notes.sqlite`.
        private var resolved: NotesStore?
        private let provider: (@Sendable () async -> NotesStore?)?
        private var store: NotesStore {
            get throws {
                guard let resolved else { throw NotesError.keyUnavailable }
                return resolved
            }
        }
        let now: @Sendable () -> Date
        let log: any NotesLogging
        var docID: Int64?
        var seed: SeedPlan?
        var needsReload = false
        var headID: Int64 = 0
        var headBody = ""
        var headBlocks: [(text: String, block: StoredBlock)] = []
        var attribution = BlockAttribution()
        var sessionRevisionID: Int64?
        var lastSerial = 0
        /// The `proposed` human revision holding the text since a compare-and-set loss; `nil` when none.
        var conflictProposalID: Int64?
        let sourceStartedAtMs: (@Sendable () async -> Int64?)?

        init(
            store: NotesStore?, provider: (@Sendable () async -> NotesStore?)?, target: Target,
            now: @escaping @Sendable () -> Date, sourceStartedAtMs: (@Sendable () async -> Int64?)?,
            log: any NotesLogging
        ) {
            self.resolved = store
            self.provider = provider
            self.now = now
            self.sourceStartedAtMs = sourceStartedAtMs
            self.log = log
            switch target {
            case .existing(let id):
                docID = id
                needsReload = true
            case .seed(let plan):
                seed = plan
            }
        }

        private var logKey: String?
        private var keyForLog: String? { logKey ?? seed.map(\.key.rawValue) }

        func closeSession() { sessionRevisionID = nil }

        /// The store, opened through the provider the first time a write needs it.
        func openStore() async throws -> NotesStore {
            if let resolved { return resolved }
            guard let opened = await provider?() else { throw NotesError.keyUnavailable }
            resolved = opened
            return opened
        }

        /// Seeds the overlay when there is none (only the seed revision, no human one), then reports the head.
        func ensureDocument() async throws -> Head {
            let store = try await openStore()
            if let reason = store.blockedReason { throw reason }
            if docID == nil {
                guard let plan = seed else { throw NotesError.guardRejected(rule: "seed") }
                if let current = await sourceStartedAtMs?(), current != plan.startedAtMs {
                    // The recording was recreated since the editor rendered it: its text is not this note's.
                    log.error(NotesLogEvent("seed", code: "startedAtChanged", key: keyForLog))
                    throw NotesError.guardRejected(rule: "startedAtChanged")
                }
                let document = try OverlaySeeder.seed(plan, in: store, now: now())
                if let started = document.sourceStartedAtMs, started != plan.startedAtMs {
                    throw NotesError.guardRejected(rule: "startedAtChanged")
                }
                docID = document.id
                seed = nil
                needsReload = true
            }
            try reloadIfNeeded()
            guard let docID else { throw NotesError.guardRejected(rule: "noDocument") }
            return Head(docID: docID, revisionID: headID, body: headBody)
        }

        private func reloadIfNeeded() throws {
            guard needsReload, let docID else { return }
            guard let document = try store.document(id: docID) else {
                throw NotesError.guardRejected(rule: "noDocument")
            }
            logKey = document.key.rawValue
            let chain = try store.revisions(of: docID)
            attribution = BlockAttribution(
                chain: chain.filter { $0.state == .applied }.map { ($0.author, $0.body) })
            if let head = chain.first(where: { $0.id == document.headRevisionID }) {
                setHead(head.id, body: head.body, stored: StoredBlocks.decode(head.blocksJSON), author: head.author)
            }
            sessionRevisionID = nil
            needsReload = false
        }

        private func setHead(_ id: Int64, body: String, stored: StoredBlocks?, author: String) {
            headID = id
            headBody = body
            let texts = MarkdownBlocks.split(body)
            if let stored, stored.blocks.count == texts.count {
                headBlocks = Array(zip(texts, stored.blocks)).map { ($0, $1) }
            } else {
                headBlocks = texts.map { ($0, StoredBlock(author: author)) }
            }
        }

        // MARK: Typing

        func writeHuman(_ text: String, serial: Int) async throws -> Outcome {
            guard serial > lastSerial else { return .nothing }
            let store = try await openStore()
            if let reason = store.blockedReason { throw reason }
            if docID == nil { return try await seedAndWrite(text, serial: serial) }
            try reloadIfNeeded()
            guard let docID else { return .nothing }
            if text == headBody {
                lastSerial = serial
                return .nothing
            }
            let blocks = attribution.stored(body: text, author: "human", previous: headBlocks)
            if let proposalID = conflictProposalID {
                // After a compare-and-set loss the editor buffer is stale against the head: never write it over
                // the head again. It keeps going into the one proposal until Restore/Apply resolves the conflict.
                lastSerial = serial
                if try store.amendProposal(
                    docID: docID, revisionID: proposalID, body: text, blocksJSON: blocks.json, now: now())
                {
                    return .keptAsProposal(revisionID: proposalID)
                }
                return try keepAsProposal(text, blocks: blocks, docID: docID)
            }
            if let session = sessionRevisionID, session == headID,
                try store.amendHead(docID: docID, revisionID: session, body: text, blocksJSON: blocks.json, now: now())
            {
                attribution.add(author: "human", body: text)
                setHead(session, body: text, stored: blocks, author: "human")
                lastSerial = serial
                return .amended(revisionID: session)
            }
            sessionRevisionID = nil
            let revision = NewNoteRevision(
                docID: docID, author: "human", state: .applied, body: text, blocksJSON: blocks.json, now: now(),
                expectedHeadID: headID)
            do {
                let id = try store.appendRevision(revision)
                attribution.add(author: "human", body: text)
                setHead(id, body: text, stored: blocks, author: "human")
                sessionRevisionID = id
                lastSerial = serial
                pruneAfterWrite()
                return .appended(revisionID: id)
            } catch NotesError.casConflict {
                // The head moved under the writer (a defect path: only this writer moves heads). Keep the text.
                log.error(NotesLogEvent("write", code: NotesError.casConflict.code, key: keyForLog))
                lastSerial = serial
                return try keepAsProposal(text, blocks: blocks, docID: docID)
            }
        }

        private func keepAsProposal(_ text: String, blocks: StoredBlocks, docID: Int64) throws -> Outcome {
            let id = try store.appendRevision(
                NewNoteRevision(
                    docID: docID, author: "human", state: .proposed, body: text, blocksJSON: blocks.json,
                    metaJSON: NoteMeta.json(["cas_conflict": true]), now: now()))
            conflictProposalID = id
            needsReload = true
            return .keptAsProposal(revisionID: id)
        }

        private func seedAndWrite(_ text: String, serial: Int) async throws -> Outcome {
            guard let plan = seed else { throw NotesError.guardRejected(rule: "seed") }
            let current = await sourceStartedAtMs?()
            if let existing = try store.liveDocument(key: plan.key, layer: plan.layerID) {
                if let started = existing.sourceStartedAtMs, started != plan.startedAtMs {
                    // The source was recreated since this editor rendered it: the text belongs to the old recording.
                    return try seedDetached(text, serial: serial, plan: plan)
                }
                // Another writer (a comment, the agent) seeded the layer first: write on top of it.
                docID = existing.id
                seed = nil
                needsReload = true
                return try await writeHuman(text, serial: serial)
            }
            if let current, current != plan.startedAtMs {
                return try seedDetached(text, serial: serial, plan: plan)
            }
            if text == plan.snapshot.markdown {
                lastSerial = serial
                return .nothing
            }
            var seeded = BlockAttribution()
            seeded.add(author: plan.snapshot.author.rawValue, body: plan.snapshot.markdown)
            let seedBlocks = BlockAttribution.seeded(layer: plan.snapshot)
            setHead(0, body: plan.snapshot.markdown, stored: seedBlocks, author: plan.snapshot.author.rawValue)
            let blocks = seeded.stored(body: text, author: "human", previous: headBlocks)
            let human = NewNoteRevision(
                docID: 0, author: "human", state: .applied, body: text, blocksJSON: blocks.json, now: now())
            let result = try store.insertSeededDocument(OverlaySeeder.document(for: plan, now: now()), human: human)
            seeded.add(author: "human", body: text)
            attribution = seeded
            docID = result.docID
            seed = nil
            setHead(result.humanID, body: text, stored: blocks, author: "human")
            sessionRevisionID = result.humanID
            lastSerial = serial
            return .seeded(docID: result.docID, revisionID: result.humanID)
        }

        /// The first write came from a snapshot of a recording that is gone: the text is kept in a detached overlay
        /// (user writing, never deleted with its source) and never seeds a live row under the new recording.
        private func seedDetached(_ text: String, serial: Int, plan: SeedPlan) throws -> Outcome {
            log.error(NotesLogEvent("seed", code: "startedAtChanged", key: keyForLog))
            var seeded = BlockAttribution()
            seeded.add(author: plan.snapshot.author.rawValue, body: plan.snapshot.markdown)
            setHead(
                0, body: plan.snapshot.markdown, stored: BlockAttribution.seeded(layer: plan.snapshot),
                author: plan.snapshot.author.rawValue)
            let blocks = seeded.stored(body: text, author: "human", previous: headBlocks)
            let human = NewNoteRevision(
                docID: 0, author: "human", state: .applied, body: text, blocksJSON: blocks.json, now: now())
            var document = OverlaySeeder.document(for: plan, now: now())
            document.sourceState = .detached
            let result = try store.insertSeededDocument(document, human: human)
            seeded.add(author: "human", body: text)
            attribution = seeded
            docID = result.docID
            seed = nil
            setHead(result.humanID, body: text, stored: blocks, author: "human")
            sessionRevisionID = result.humanID
            lastSerial = serial
            return .seeded(docID: result.docID, revisionID: result.humanID)
        }

        // MARK: Other writes

        func restore(_ revisionID: Int64) async throws -> Int64 {
            let store = try await openStore()
            if let reason = store.blockedReason { throw reason }
            guard docID != nil else { throw NotesError.guardRejected(rule: "noDocument") }
            try reloadIfNeeded()
            // Only an applied revision of this document that is not already the head: a proposed or discarded one
            // was never the text, and restoring the head would write a copy of what is there.
            guard let docID, let target = try store.revision(id: revisionID), target.docID == docID,
                target.state == .applied, target.id != headID
            else {
                throw NotesError.guardRejected(rule: "restoreTarget")
            }
            let stored = StoredBlocks.decode(target.blocksJSON)
            let id = try storeApplied(
                author: "human", body: target.body, summary: nil,
                metaJSON: NoteMeta.json(["restored_from": revisionID]), blocks: stored)
            return id
        }

        func append(
            author: String, body: String, summary: String?, metaJSON: String?, state: NoteRevisionState,
            expectingHead: Int64? = nil
        ) async throws -> Int64 {
            let store = try await openStore()
            if let reason = store.blockedReason { throw reason }
            guard let docID else { throw NotesError.guardRejected(rule: "noDocument") }
            try reloadIfNeeded()
            if let expectingHead, expectingHead != headID { throw NotesError.casConflict }
            if state == .applied {
                return try storeApplied(author: author, body: body, summary: summary, metaJSON: metaJSON, blocks: nil)
            }
            let blocks = attribution.stored(body: body, author: author, previous: headBlocks)
            return try store.appendRevision(
                NewNoteRevision(
                    docID: docID, author: author, state: .proposed, body: body, summary: summary,
                    blocksJSON: blocks.json, metaJSON: metaJSON, now: now()))
        }

        func applyProposal(_ proposalID: Int64, expectingHead: Int64) async throws -> Int64 {
            let store = try await openStore()
            if let reason = store.blockedReason { throw reason }
            guard let docID else { throw NotesError.guardRejected(rule: "noDocument") }
            try reloadIfNeeded()
            if expectingHead != headID { throw NotesError.casConflict }
            guard let proposal = try store.revision(id: proposalID), proposal.docID == docID,
                proposal.state == .proposed
            else { throw NotesError.guardRejected(rule: "proposalTarget") }
            let stored =
                StoredBlocks.decode(proposal.blocksJSON)
                ?? attribution.stored(body: proposal.body, author: proposal.author, previous: headBlocks)
            let id = try store.applyProposal(
                docID: docID, proposalID: proposalID, expectedHeadID: headID, summary: nil, blocksJSON: stored.json,
                metaJSON: NoteMeta.json(["applied_from": proposalID, "base_head_id": headID]), now: now())
            attribution.add(author: proposal.author, body: proposal.body)
            setHead(id, body: proposal.body, stored: stored, author: proposal.author)
            sessionRevisionID = nil
            conflictProposalID = nil
            pruneAfterWrite()
            return id
        }

        func discardProposal(_ proposalID: Int64, confirmedRemoval: Bool) async throws {
            let store = try await openStore()
            if let reason = store.blockedReason { throw reason }
            guard let docID else { throw NotesError.guardRejected(rule: "noDocument") }
            guard
                try store.discardProposal(
                    docID: docID, proposalID: proposalID, confirmedRemoval: confirmedRemoval)
            else {
                throw NotesError.guardRejected(rule: "proposalTarget")
            }
            if conflictProposalID == proposalID { conflictProposalID = nil }
        }

        private func storeApplied(
            author: String, body: String, summary: String?, metaJSON: String?, blocks: StoredBlocks?,
            sourceVersion: String? = nil
        ) throws -> Int64 {
            guard let docID else { throw NotesError.guardRejected(rule: "noDocument") }
            let stored = blocks ?? attribution.stored(body: body, author: author, previous: headBlocks)
            let id = try store.appendRevision(
                NewNoteRevision(
                    docID: docID, author: author, state: .applied, body: body, summary: summary,
                    blocksJSON: stored.json, metaJSON: metaJSON, now: now(), expectedHeadID: headID,
                    sourceVersionSeen: sourceVersion))
            attribution.add(author: author, body: body)
            setHead(id, body: body, stored: stored, author: author)
            sessionRevisionID = nil
            conflictProposalID = nil
            pruneAfterWrite()
            return id
        }

        func reconcile(_ layer: NoteLayer) async throws -> Reconciliation {
            // No row yet (a layer that was never written): nothing to reconcile, and nothing opens the store.
            guard docID != nil else { return .unchanged }
            let store = try await openStore()
            if let reason = store.blockedReason { throw reason }
            guard let docID else { return .unchanged }
            try reloadIfNeeded()
            guard let document = try store.document(id: docID) else {
                throw NotesError.guardRejected(rule: "noDocument")
            }
            // A detached overlay never follows a source again.
            if document.sourceState == .detached { return .unchanged }
            guard document.sourceVersionSeen != layer.version else { return .unchanged }
            sessionRevisionID = nil
            if headBody == layer.markdown {
                try store.setSourceVersionSeen(docID: docID, version: layer.version)
                return .versionOnly
            }
            let author = layer.author.rawValue
            var sourceBlocks = BlockAttribution.seeded(layer: layer)
            let texts = MarkdownBlocks.split(layer.markdown)
            for index in sourceBlocks.blocks.indices where index < texts.count {
                sourceBlocks.blocks[index].author = attribution.author(of: texts[index]) ?? author
            }
            let meta = NoteMeta.json(["source_version": layer.version])
            if try store.hasUserWriting(docID) {
                let id = try store.appendRevision(
                    NewNoteRevision(
                        docID: docID, author: author, state: .proposed, body: layer.markdown,
                        blocksJSON: sourceBlocks.json, metaJSON: meta, now: now(), sourceVersionSeen: layer.version))
                return .proposed(revisionID: id)
            }
            let id = try storeApplied(
                author: author, body: layer.markdown, summary: nil, metaJSON: meta, blocks: sourceBlocks,
                sourceVersion: layer.version)
            return .applied(revisionID: id)
        }

        private func pruneAfterWrite() {
            guard let docID else { return }
            do {
                try store.prune(docID: docID)
            } catch {
                log.error(NotesLogEvent("prune", code: (error as? NotesError)?.code ?? "pruneFailed"))
            }
        }
    }
}

/// `note_revision.meta_json`: model id, prompt version, comment ids, `restored_from`, `base_head_id`. Built with
/// a serializer, never by string interpolation.
enum NoteMeta {
    static func json(_ values: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(values),
            let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
