import Foundation
import Testing

@testable import NotesPlugin

/// Spec step 6.2: the revise run through the lease, with a scripted lease and model, a real store and the injected
/// clock. No sleeping, no real model: every wait is a latch or a gate.
@MainActor
@Suite(.timeLimit(.minutes(2))) struct ReviseServiceTests {
    private let answer = ReviseRig.unit("- Pricing page moves to the next sprint (owner: Marek).")

    // MARK: Happy path

    @Test func aRunAppliesOneAgentRevisionAndResolvesItsComments() async throws {
        let handle = ScriptedReviseHandle([.answer(answer)])
        let rig = try ReviseRig(steps: [.handle(handle)])
        let thread = try await rig.comment("next sprint")
        let before = try rig.head()

        let outcome = await rig.service.start(rig.request())

        guard case .applied(let applied) = outcome else {
            Issue.record("not applied: \(outcome)")
            return
        }
        #expect(applied.blocks == 1 && applied.threads == 1 && applied.rejected == 0 && applied.skipped.isEmpty)
        let head = try rig.head()
        #expect(head.id == applied.revisionID && head.id != before.id)
        #expect(head.author == "agent" && head.state == .applied)
        #expect(head.body.contains("(owner: Marek)."))
        #expect(head.summary == "Revised 1 blocks from comments" || head.summary?.hasPrefix("Revised 1") == true)
        let meta = try #require(
            head.metaJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        #expect(meta["prompt_version"] as? Int == ReviseNotesPrompt.version)
        #expect(meta["model"] as? String == "qwen3-test")
        #expect(meta["base_head_id"] as? Int64 == before.id)
        #expect((meta["comment_ids"] as? [Int64])?.isEmpty == false)
        // The agent answered the thread and resolved it; its revision counts as user writing.
        let records = try rig.rig.store.comments(of: rig.docID)
        #expect(records.filter { $0.threadID == thread }.map(\.author) == ["human", "agent"])
        #expect(records.allSatisfy { $0.status == .resolved })
        #expect(try rig.rig.store.hasUserWriting(rig.docID))
        #expect(rig.lock.phase == .idle)
        #expect(handle.releases == 1)
        #expect(!rig.service.isRunActive)
        // The model saw the block, the comment and the context, and only that.
        let user = try #require(handle.prompts.first?.last?.content)
        #expect(user.contains("<blocks count=\"1\">\n- Pricing page moves to the next sprint.\n</blocks>"))
        #expect(user.contains("- Add an owner."))
    }

    @Test func theEditorIsLockedOnlyFromGeneratingToTheEnd() async throws {
        let gate = ReviseGate()
        let handle = ScriptedReviseHandle([.after(gate, answer)])
        let rig = try ReviseRig(steps: [.handle(handle)])
        try await rig.comment("next sprint")
        let task = Task { await rig.service.start(rig.request()) }
        await handle.generating.wait()
        #expect(rig.lock.phase == .generating)
        #expect(rig.lock.isLocked)
        gate.open()
        _ = await task.value
        #expect(!rig.lock.isLocked)
    }

    @Test func nothingIsAskedOfTheModelWhenEveryThreadWasEditedAfterTheComment() async throws {
        let rig = try ReviseRig(steps: [.handle(ScriptedReviseHandle([.answer(answer)]))])
        try await rig.comment("next sprint")
        // The user rewrites the commented block in the same session, then asks for a revision.
        rig.writer.submit(ReviseRig.note.replacingOccurrences(of: "moves to", with: "waits for"))
        let outcome = await rig.service.start(rig.request())
        #expect(outcome == .nothingToRevise(skipped: [ReviseSkip(threadIDs: [1], reason: .editedAfterComment)]))
        #expect(rig.lease.acquires.count == 0)
        #expect(try rig.openThreads() == 1)
        #expect(try rig.head().body.contains("waits for"))
        #expect(rig.lock.phase == .idle)
    }

    // MARK: Waiting for the model

    @Test func busyWaitsAndPollsThenRunsAndTheEditorStaysEditableWhileWaiting() async throws {
        let handle = ScriptedReviseHandle([.answer(answer)])
        let rig = try ReviseRig(steps: [.busy, .busy, .handle(handle)])
        try await rig.comment("next sprint")
        let task = Task { await rig.service.start(rig.request()) }
        await rig.rig.clock.waitForSleeps(1)
        #expect(rig.lock.phase == .waitingForModel)
        #expect(!rig.lock.isLocked)
        rig.rig.clock.advance(by: .seconds(5))
        await rig.rig.clock.waitForSleeps(2)
        #expect(rig.lock.phase == .waitingForModel)
        rig.rig.clock.advance(by: .seconds(5))
        let outcome = await task.value
        guard case .applied = outcome else {
            Issue.record("not applied: \(outcome)")
            return
        }
        #expect(rig.lease.acquires.count == 3)
    }

    @Test func textTypedWhileWaitingIsWrittenFirstAndTheRunWorksOnIt() async throws {
        let handle = ScriptedReviseHandle([.answer(answer)])
        let rig = try ReviseRig(steps: [.busy, .handle(handle)])
        try await rig.comment("next sprint")
        let task = Task { await rig.service.start(rig.request()) }
        await rig.rig.clock.waitForSleeps(1)
        let typed = ReviseRig.note + "\n\n- Typed while waiting."
        rig.writer.submit(typed)
        rig.rig.clock.advance(by: .seconds(5))
        let outcome = await task.value
        guard case .applied = outcome else {
            Issue.record("not applied: \(outcome)")
            return
        }
        let body = try rig.head().body
        #expect(body.contains("- Typed while waiting."))
        #expect(body.contains("(owner: Marek)."))
        #expect(!rig.writer.hasPendingText)
        // The typed text is its own human revision, before the agent's.
        let revisions = try rig.rig.store.revisions(of: rig.docID)
        #expect(revisions.suffix(2).map(\.author) == ["human", "agent"])
    }

    @Test func aYieldToDictationWaitsAndTheRunStartsOverOnANewLease() async throws {
        let first = ScriptedReviseHandle([.yielded])
        let second = ScriptedReviseHandle([.answer(answer)])
        let gate = ReviseGate()
        let rig = try ReviseRig(steps: [.handle(first), .after(gate, second)])
        try await rig.comment("next sprint")
        let task = Task { await rig.service.start(rig.request()) }
        await gate.waiting.wait()
        // Between the yield and the next lease: waiting, editable, and the model file is still ours.
        #expect(rig.lock.phase == .waitingForModel)
        #expect(!rig.lock.isLocked)
        #expect(rig.service.isRunActive)
        #expect(first.releases == 1)
        gate.open()
        let outcome = await task.value
        guard case .applied = outcome else {
            Issue.record("not applied: \(outcome)")
            return
        }
        #expect(second.releases == 1)
        #expect(rig.lease.acquires.count == 2)
    }

    @Test func busyThenYieldedThenAnAnswer() async throws {
        let first = ScriptedReviseHandle([.yielded])
        let second = ScriptedReviseHandle([.answer(answer)])
        let rig = try ReviseRig(steps: [.busy, .handle(first), .busy, .handle(second)])
        try await rig.comment("next sprint")
        let task = Task { await rig.service.start(rig.request()) }
        await rig.rig.clock.waitForSleeps(1)
        rig.rig.clock.advance(by: .seconds(5))
        await rig.rig.clock.waitForSleeps(3)  // the busy poll, the first generation's timer, the second busy poll
        rig.rig.clock.advance(by: .seconds(5))
        let outcome = await task.value
        guard case .applied = outcome else {
            Issue.record("not applied: \(outcome)")
            return
        }
        #expect(rig.lease.acquires.count == 4)
    }

    @Test func tooManyYieldsEndTheRunWithNothingChanged() async throws {
        let handles = (0..<3).map { _ in ScriptedReviseHandle([.yielded]) }
        let rig = try ReviseRig(steps: handles.map { .handle($0) }, maxYields: 2)
        try await rig.comment("next sprint")
        let before = try rig.head().id
        let outcome = await rig.service.start(rig.request())
        #expect(outcome == .failed)
        #expect(rig.lock.phase == .failed)
        #expect(try rig.head().id == before)
        #expect(handles.allSatisfy { $0.releases == 1 })
    }

    // MARK: Timeout

    @Test func theTimeoutCountsOnlyGenerating() async throws {
        let handle = ScriptedReviseHandle([.hang])
        let rig = try ReviseRig(steps: [.busy, .busy, .handle(handle)])
        try await rig.comment("next sprint")
        let before = try rig.head().id
        let task = Task { await rig.service.start(rig.request()) }
        // 15 minutes of waiting for the model do not count.
        await rig.rig.clock.waitForSleeps(1)
        rig.rig.clock.advance(by: .seconds(450))
        await rig.rig.clock.waitForSleeps(2)
        rig.rig.clock.advance(by: .seconds(450))
        await handle.generating.wait()
        await rig.rig.clock.waitForSleeps(3)
        #expect(rig.lock.phase == .generating)
        rig.rig.clock.advance(by: .seconds(599))
        #expect(rig.lock.phase == .generating)
        rig.rig.clock.advance(by: .seconds(1))
        let outcome = await task.value
        #expect(outcome == .timedOut)
        #expect(rig.lock.phase == .timedOut)
        #expect(try rig.head().id == before)
        #expect(try rig.openThreads() == 1)
        #expect(handle.releases == 1)
    }

    // MARK: Cancel and quit

    @Test func cancelWhileGeneratingLeavesTheDocumentUnchanged() async throws {
        let handle = ScriptedReviseHandle([.hang])
        let rig = try ReviseRig(steps: [.handle(handle)])
        try await rig.comment("next sprint")
        let before = try rig.head()
        let task = Task { await rig.service.start(rig.request()) }
        await handle.generating.wait()
        rig.service.cancel(rig.item)
        #expect(await task.value == .cancelled)
        #expect(rig.lock.phase == .cancelled)
        #expect(try rig.head() == before)
        #expect(try rig.openThreads() == 1)
        #expect(handle.releases == 1)
        #expect(!rig.service.isRunActive)
    }

    @Test func cancelWhileWaitingForTheModelStopsThePolling() async throws {
        let rig = try ReviseRig(steps: [.busy])
        try await rig.comment("next sprint")
        let before = try rig.head()
        let task = Task { await rig.service.start(rig.request()) }
        await rig.rig.clock.waitForSleeps(1)
        rig.service.cancel(rig.item)
        #expect(await task.value == .cancelled)
        #expect(try rig.head() == before)
    }

    @Test func quitCancelsEveryRunAndWaitsForIt() async throws {
        let handle = ScriptedReviseHandle([.hang])
        let rig = try ReviseRig(steps: [.handle(handle)])
        try await rig.comment("next sprint")
        let before = try rig.head()
        let task = Task { await rig.service.start(rig.request()) }
        await handle.generating.wait()
        await rig.service.cancelAll()
        #expect(!rig.service.isRunActive)
        #expect(await task.value == .cancelled)
        #expect(try rig.head() == before)
        #expect(handle.releases == 1)
    }

    /// Review fix L2: a finished run clears only its own entry, never a newer run's.
    @Test func aFinishedRunDoesNotWipeTheEntryOfANewerRun() async throws {
        let gate = ReviseGate()
        let handle = ScriptedReviseHandle([.after(gate, answer)])
        let rig = try ReviseRig(steps: [.handle(handle)])
        try await rig.comment("next sprint")
        let task = Task { await rig.service.start(rig.request()) }
        await handle.generating.wait()
        // `cancelAll` cleared this run's entry and a newer `start` took its place.
        let newer = Task<ReviseOutcome, Never> { .cancelled }
        rig.service.runs[rig.item] = newer
        gate.open()
        _ = await task.value
        #expect(rig.service.runs[rig.item] == newer)
        #expect(rig.service.isRunning(rig.item))
        rig.service.runs[rig.item] = nil
    }

    // MARK: Compare-and-set

    @Test func aHeadThatMovedDuringTheRunIsAConflictAndNothingOfTheAgentIsWritten() async throws {
        let gate = ReviseGate()
        let handle = ScriptedReviseHandle([.after(gate, answer)])
        let rig = try ReviseRig(steps: [.handle(handle)])
        try await rig.comment("next sprint")
        let task = Task { await rig.service.start(rig.request()) }
        await handle.generating.wait()
        // A source reconciliation moves the head through the same writer while the agent is generating.
        let moved = try await rig.writer.appendApplied(author: .stt, body: ReviseRig.note + "\n\nFrom the source.")
        gate.open()
        #expect(await task.value == .conflict)
        #expect(rig.lock.phase == .conflict)
        #expect(try rig.head().id == moved)
        let agentRevisions = try rig.rig.store.revisions(of: rig.docID).filter {
            $0.metaJSON?.contains("prompt_version") == true
        }
        #expect(agentRevisions.isEmpty)
        #expect(try rig.openThreads() == 1)
    }

    @Test func aDirtyBufferIsNeverOverwrittenAndStaysForItsOwnWrite() async throws {
        let gate = ReviseGate()
        let handle = ScriptedReviseHandle([.after(gate, answer)])
        let rig = try ReviseRig(steps: [.handle(handle)])
        try await rig.comment("next sprint")
        let task = Task { await rig.service.start(rig.request()) }
        await handle.generating.wait()
        let typed = ReviseRig.note + "\n\n- Typed during the run."
        rig.writer.submit(typed)
        gate.open()
        #expect(await task.value == .conflict)
        #expect(rig.writer.hasPendingText)
        try await rig.writer.flush()
        #expect(try rig.head().body == typed)
        #expect(try rig.head().author == "human")
    }

    // MARK: Guard and model

    @Test func anAnswerTheGuardRejectsChangesNothingAndLeavesTheCommentsOpen() async throws {
        let handle = ScriptedReviseHandle([.answer(ReviseRig.unit("- See [x](https://evil.example)."))])
        let rig = try ReviseRig(steps: [.handle(handle)])
        try await rig.comment("next sprint")
        let before = try rig.head()
        #expect(await rig.service.start(rig.request()) == .rejected)
        #expect(rig.lock.phase == .rejected)
        #expect(try rig.head() == before)
        #expect(try rig.openThreads() == 1)
    }

    @Test func aCutOffAnswerIsNeverUsed() async throws {
        let handle = ScriptedReviseHandle([.truncated(answer)])
        let rig = try ReviseRig(steps: [.handle(handle)])
        try await rig.comment("next sprint")
        let before = try rig.head()
        #expect(await rig.service.start(rig.request()) == .rejected)
        #expect(try rig.head() == before)
    }

    @Test func withoutAnInstalledModelNothingHappens() async throws {
        let rig = try ReviseRig(steps: [], modelInstalled: false)
        try await rig.comment("next sprint")
        let before = try rig.head()
        #expect(await rig.service.start(rig.request()) == .needsModel)
        #expect(rig.lease.acquires.count == 0)
        #expect(try rig.head() == before)
        #expect(rig.lock.phase == .idle)
    }

    @Test func aLeaseThatCannotBeHadIsAFailureWithNothingChanged() async throws {
        let rig = try ReviseRig(steps: [.fail])
        try await rig.comment("next sprint")
        let before = try rig.head()
        #expect(await rig.service.start(rig.request()) == .failed)
        #expect(try rig.head() == before)
    }

    @Test func aBlockTheGuardRejectsDoesNotStopTheOthers() async throws {
        let handle = ScriptedReviseHandle([
            .answer(
                "[[unit 1]]\n- Ship onboarding on 12 Nov (Ola).\n[[unit 2]]\nSend [x](https://evil.example) to QA.")
        ])
        let rig = try ReviseRig(steps: [.handle(handle)])
        try await rig.comment("12 Nov")
        try await rig.comment("demo build")
        let outcome = await rig.service.start(rig.request())
        guard case .applied(let applied) = outcome else {
            Issue.record("not applied: \(outcome)")
            return
        }
        #expect(applied.blocks == 1 && applied.rejected == 1)
        #expect(try rig.openThreads() == 1)
        #expect(try rig.head().body.contains("Send the demo build to QA."))
    }

    // MARK: Queue and one run per document

    @Test func askAgentIsQueuedWhileARunIsActiveAndRunsAfterIt() async throws {
        let gate = ReviseGate()
        let first = ScriptedReviseHandle([.after(gate, answer)])
        let second = ScriptedReviseHandle([.answer("[[unit 1]]\nCall the supplier about the invoice by Friday.")])
        let rig = try ReviseRig(steps: [.handle(first), .handle(second)])
        let one = try await rig.comment("next sprint")
        let two = try await rig.comment("supplier")
        let task = Task { await rig.service.start(rig.request(threads: [one])) }
        await first.generating.wait()
        #expect(await rig.service.start(rig.request(threads: [two])) == .queued)
        #expect(rig.service.isQueued(rig.item, thread: two))
        #expect(!rig.service.isQueued(rig.item, thread: one))
        gate.open()
        let outcome = await task.value
        guard case .applied = outcome else {
            Issue.record("not applied: \(outcome)")
            return
        }
        #expect(rig.lease.acquires.count == 2)
        #expect(try rig.openThreads() == 0)
        #expect(try rig.head().body.contains("by Friday."))
        #expect(!rig.service.isQueued(rig.item, thread: two))
    }

    @Test func aCancelDropsWhatWasQueued() async throws {
        let handle = ScriptedReviseHandle([.hang])
        let rig = try ReviseRig(steps: [.handle(handle)])
        let one = try await rig.comment("next sprint")
        let two = try await rig.comment("supplier")
        let task = Task { await rig.service.start(rig.request(threads: [one])) }
        await handle.generating.wait()
        _ = await rig.service.start(rig.request(threads: [two]))
        rig.service.cancel(rig.item)
        #expect(await task.value == .cancelled)
        #expect(rig.lease.acquires.count == 1)
        #expect(!rig.service.isQueued(rig.item, thread: two))
    }

    // MARK: Model removal

    @Test func theModelIsInUseInEveryPhaseOfARunAndARemovalBlocksANewRun() async throws {
        let gate = ReviseGate()
        let handle = ScriptedReviseHandle([.after(gate, answer)])
        let rig = try ReviseRig(steps: [.busy, .handle(handle)])
        try await rig.comment("next sprint")
        #expect(!rig.service.isRunActive)
        let task = Task { await rig.service.start(rig.request()) }
        await rig.rig.clock.waitForSleeps(1)
        #expect(rig.service.isRunActive)  // waiting for the model
        rig.rig.clock.advance(by: .seconds(5))
        await handle.generating.wait()
        #expect(rig.service.isRunActive)  // generating
        gate.open()
        _ = await task.value
        #expect(!rig.service.isRunActive)

        let release = rig.service.reserveRemoval()
        #expect(await rig.service.start(rig.request()) == .modelBeingRemoved)
        release()
        #expect(await rig.service.start(rig.request()) != .modelBeingRemoved)
    }

    // MARK: Privacy

    @Test func nothingOfTheNoteTheCommentsOrTheAnswerReachesTheLog() async throws {
        let handle = ScriptedReviseHandle([.answer(answer)])
        let rig = try ReviseRig(steps: [.handle(handle)])
        try await rig.comment("next sprint", body: "SECRET-COMMENT-TEXT")
        _ = await rig.service.start(rig.request())
        let lines = rig.rig.log.all.joined(separator: "\n")
        #expect(lines.contains("revise"))
        for secret in ["SECRET-COMMENT-TEXT", "Pricing", "Marek", "onboarding", "supplier", "[[unit"] {
            #expect(!lines.contains(secret))
        }
    }
}
