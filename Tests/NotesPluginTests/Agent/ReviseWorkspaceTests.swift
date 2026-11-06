import AppKit
import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

/// Spec step 6.2: the workspace around the revise run: the lock strip, "Ask agent", the report strips, the editor
/// lock and the tab that closes under a run. The service is the real one over a scripted lease; no window.
@MainActor
@Suite(.timeLimit(.minutes(2))) struct ReviseWorkspaceTests {
    private let notes = ReviseFixtures.note

    private struct Setup {
        let r: ReconRig
        let model: NotesWorkspaceModel
        let item: NoteItemID
        let service: ReviseService
        let lease: ScriptedReviseLease
    }

    private func setup(steps: [ScriptedReviseLease.Step], modelInstalled: Bool = true) async throws -> Setup {
        let r = try ReconRig()
        r.publish([r.rig.layer(notes, id: "notes", version: "n1")])
        let lease = ScriptedReviseLease(steps)
        let service = ReviseService(
            ReviseService.Dependencies(
                clock: RunClock(r.rig.clock),
                model: { modelInstalled ? ResolvedReviseModel(id: "qwen3-test", leasing: lease) : nil }))
        var environment = NotesWorkspaceModel.Environment(library: r.library, pasteboard: RecordingPasteboard())
        environment.registry = r.registry
        let store = r.store
        environment.overlayHeads = { item in (try? NoteOverlayContent.heads(for: item, in: store)) ?? [] }
        environment.canEditNotes = true
        environment.installComments(store: { store })
        environment.installHistory(store: { store })
        environment.installRevise(service: service, store: { store }, registry: r.registry, clock: r.rig.clock)
        environment.makeEditingSession = { content, layerID, document in
            NoteEditingSession.make(
                content: content, layerID: layerID, store: store, registry: r.registry, model: document, readOnly: false
            )
        }
        let model = NotesWorkspaceModel(environment: environment)
        let item = NoteItemID.live(r.key)
        model.open(item)
        await model.loadContent(item)
        return Setup(r: r, model: model, item: item, service: service, lease: lease)
    }

    @discardableResult
    private func comment(_ s: Setup, _ quote: String, _ body: String = "Add an owner.") async -> Bool {
        s.model.beginEditing(s.item)
        return await s.model.addComment(
            body: body, selection: (notes as NSString).range(of: quote), buffer: notes)
    }

    private func stripIDs(_ s: Setup) -> [String] { s.model.strips.map(\.id) }

    private let answer = ReviseRig.unit("- Pricing page moves to the next sprint (owner: Marek).")

    // MARK: Revise with N comments

    @Test func theButtonRunsTheAgentAndTheNoteShowsTheRevisionAndTheReport() async throws {
        let handle = ScriptedReviseHandle([.answer(answer)])
        let s = try await setup(steps: [.handle(handle)])
        await comment(s, "next sprint")
        let document = try #require(s.model.documents[s.item])
        #expect(s.model.canRevise)
        await s.model.revise()
        #expect(document.openCommentCount == 0)
        #expect(document.markdown?.contains("(owner: Marek).") == true)
        #expect(stripIDs(s).contains("revise.done"))
        #expect(!stripIDs(s).contains("revise.writing"))
        #expect(document.lock.phase == .idle)
        // The editor is built again on the new text.
        #expect(document.isEditing)
        // Closing any report strip closes the report.
        s.model.dismissStrip("revise.done")
        #expect(!stripIDs(s).contains("revise.done"))
        #expect(!s.model.canRevise)
    }

    @Test func theLockStripWithCancelShowsWhileGeneratingAndTheEditorIsReadOnly() async throws {
        let gate = ReviseGate()
        let handle = ScriptedReviseHandle([.after(gate, answer)])
        let s = try await setup(steps: [.handle(handle)])
        await comment(s, "next sprint")
        let document = try #require(s.model.documents[s.item])
        let session = try #require(document.session)
        #expect(session.isEditable)
        let task = Task { await s.model.revise() }
        await handle.generating.wait()
        let strip = try #require(s.model.strips.first { $0.id == "revise.writing" })
        #expect(strip.text == "Agent is writing notes · read-only until it finishes")
        #expect(strip.actions.map(\.id) == ["revise.cancel"])
        #expect(!session.isEditable)
        #expect(!s.model.canRevise)
        #expect(!session.canComment)
        // Typing is ignored while locked: nothing reaches the writer.
        session.handle(NoteEditorEdit(text: notes + " typed", range: 0..<5, changeInLength: 5))
        #expect(!(session.writer.hasPendingText))
        // Restore is refused while the agent writes.
        #expect(
            !s.model.canRestore(
                document, HistorySnapshot(docID: 1, layer: "notes", headID: 1, revisions: [], isDetached: false)))
        gate.open()
        await task.value
        #expect(!stripIDs(s).contains("revise.writing"))
    }

    @Test func commentsCannotBeChangedWhileTheAgentWritesButAskAgentStaysQueueable() async throws {
        let gate = ReviseGate()
        let handle = ScriptedReviseHandle([.after(gate, answer)])
        let s = try await setup(steps: [.handle(handle)])
        await comment(s, "next sprint")
        let document = try #require(s.model.documents[s.item])
        guard case .loaded(let snapshot) = document.comments, let thread = snapshot.threads.first else {
            Issue.record("no thread")
            return
        }
        let task = Task { await s.model.revise() }
        await handle.generating.wait()
        #expect(!s.model.canWriteComments(document))
        #expect(s.model.canAskAgent(document))
        #expect(await s.model.reply(to: thread, body: "Too late.") == false)
        await s.model.setStatus(.resolved, of: thread)
        #expect(await s.model.addComment(body: "No.", selection: NSRange(location: 0, length: 5), buffer: notes) == false)
        gate.open()
        await task.value
        let records = try s.r.store.comments(of: snapshot.docID)
        #expect(!records.contains { $0.body == "Too late." || $0.body == "No." })
    }

    @Test func cancelInTheStripStopsTheRunAndTheNoteStaysAsItWas() async throws {
        let handle = ScriptedReviseHandle([.hang])
        let s = try await setup(steps: [.handle(handle)])
        await comment(s, "next sprint")
        let document = try #require(s.model.documents[s.item])
        let before = document.markdown
        let task = Task { await s.model.revise() }
        await handle.generating.wait()
        await s.model.perform("revise.cancel")
        await task.value
        #expect(document.markdown == before)
        #expect(document.openCommentCount == 1)
        #expect(document.lock.phase == .idle)
        #expect(document.reviseReport == nil)
        #expect(!stripIDs(s).contains { $0.hasPrefix("revise.") })
        #expect(s.model.canRevise)
    }

    @Test func whileTheModelIsBusyTheStripSaysSoAndTheEditorStaysEditable() async throws {
        let s = try await setup(steps: [.busy])
        await comment(s, "next sprint")
        let document = try #require(s.model.documents[s.item])
        let task = Task { await s.model.revise() }
        await s.r.rig.clock.waitForSleeps(1)
        let strip = try #require(s.model.strips.first { $0.id == "revise.waiting" })
        #expect(strip.text == "Waiting for the model")
        #expect(strip.actions.map(\.id) == ["revise.cancel"])
        #expect(document.session?.isEditable == true)
        s.service.cancel(s.item)
        await task.value
    }

    @Test func closingTheTabCancelsItsRun() async throws {
        let handle = ScriptedReviseHandle([.hang])
        let s = try await setup(steps: [.handle(handle)])
        await comment(s, "next sprint")
        let task = Task { await s.model.revise() }
        await handle.generating.wait()
        s.model.close(s.item)
        await task.value
        #expect(!s.service.isRunActive)
        #expect(handle.releases == 1)
    }

    // MARK: Ask agent

    @Test func askAgentRevisesOnlyThatThreadAndIsQueuedBehindARunningOne() async throws {
        let gate = ReviseGate()
        let first = ScriptedReviseHandle([.after(gate, answer)])
        let second = ScriptedReviseHandle([.answer("[[unit 1]]\nCall the supplier about the invoice by Friday.")])
        let s = try await setup(steps: [.handle(first), .handle(second)])
        await comment(s, "next sprint")
        await comment(s, "supplier")
        let document = try #require(s.model.documents[s.item])
        let threads = document.commentThreads
        #expect(threads.count == 2)
        let task = Task { await s.model.askAgent(threads[0]) }
        await first.generating.wait()
        // The first run takes only its thread; the second is queued and shows "Queued".
        let queued = Task { await s.model.askAgent(threads[1]) }
        await queued.value
        #expect(s.model.isAskQueued(document, thread: threads[1]))
        #expect(!s.model.isAskQueued(document, thread: threads[0]))
        gate.open()
        await task.value
        #expect(document.openCommentCount == 0)
        #expect(document.markdown?.contains("by Friday.") == true)
        #expect(!s.model.isAskQueued(document, thread: threads[1]))
    }

    // MARK: Reports

    @Test func theReportsAreStripsInWordsWithNothingOfTheNote() throws {
        typealias M = NotesWorkspaceModel
        func texts(_ outcome: ReviseOutcome) -> [String] { M.reportStrips(outcome).map(\.text) }
        func actions(_ outcome: ReviseOutcome) -> [[String]] { M.reportStrips(outcome).map { $0.actions.map(\.id) } }

        #expect(texts(.rejected) == ["The agent’s answer couldn’t be used. Nothing was changed."])
        #expect(actions(.rejected) == [["revise.retry"]])
        #expect(texts(.conflict) == ["The note changed while the agent was working. Nothing was changed."])
        #expect(texts(.timedOut) == ["The agent took too long. Nothing was changed."])
        #expect(actions(.timedOut) == [["revise.retry"]])
        #expect(texts(.failed) == ["The agent couldn’t finish. Nothing was changed."])
        #expect(texts(.modelBeingRemoved) == ["The notes model is being removed. Try again in a moment."])
        #expect(texts(.cancelled).isEmpty && texts(.queued).isEmpty)
        #expect(actions(.needsModel) == [["models.open"]])
        #expect(M.reportStrips(.needsModel).first?.id == "revise.needsModel")

        let one = ReviseSkip(threadIDs: [1], reason: .editedAfterComment)
        // `swift test` has no compiled catalog, so the text is the interpolated key; the app picks the plural form
        // ("You edited this block, so it was not changed." for one), which `NotesAgentCopyTests` checks in the catalog.
        #expect(texts(.nothingToRevise(skipped: [one])) == ["You edited 1 blocks, so they were not changed."])
        let two = ReviseSkip(threadIDs: [2, 3], reason: .editedAfterComment)
        #expect(texts(.nothingToRevise(skipped: [one, two])) == ["You edited 3 blocks, so they were not changed."])
        #expect(texts(.nothingToChange(skipped: [])) == ["The agent found nothing to change. The comments stay open."])

        let applied = ReviseOutcome.Applied(revisionID: 9, blocks: 2, threads: 2, skipped: [one], rejected: 1)
        let ids = M.reportStrips(.applied(applied)).map(\.id)
        #expect(ids == ["revise.done", "revise.rejected.blocks", "revise.skipped.edited"])
        #expect(texts(.applied(applied)).first == "Revised 2 blocks from comments. Restore is in History.")
        let dismissible = M.reportStrips(.applied(applied)).map { $0.isDismissible }
        #expect(!dismissible.contains(false))
    }

    @Test func aMissingModelShowsTheNeedsModelStripAndChangesNothing() async throws {
        let s = try await setup(steps: [], modelInstalled: false)
        await comment(s, "next sprint")
        let document = try #require(s.model.documents[s.item])
        let before = document.markdown
        await s.model.revise()
        #expect(stripIDs(s).contains("revise.needsModel"))
        #expect(document.markdown == before)
        #expect(document.openCommentCount == 1)
    }
}
