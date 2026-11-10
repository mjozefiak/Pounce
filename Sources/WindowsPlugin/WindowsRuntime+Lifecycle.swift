import Foundation
import LintelCore
import LintelKit
import LintelUI
import os

/// The runtime's one life: `start()`, `stop()` and what guards them against each other.
extension WindowsRuntime {
    /// Where the runtime is in its one life: `start()` runs once, `stop()` ends it for good (also while a start is
    /// still suspended, which is what the host's activation budget does to a start that hangs).
    enum Phase { case idle, starting, running, stopped }

    /// Takes the journal first: when an earlier run still holds it (a stop budget ran out with a hung app) this
    /// gives up after `startBudget` and starts nothing, so a re-enable fails with a message instead of hanging.
    ///
    /// A `stop()` that comes while this is suspended, or a cancelled caller (the host gave up waiting), ends the
    /// start at its next step with `CancellationError`: nothing is created after that point, and a journal lease
    /// taken late is handed back here because `stop()` could not know about it.
    func start() async throws {
        guard phase == .idle else { throw CancellationError() }
        phase = .starting
        try await acquireJournal()
        try continueStart()
        trust.refresh()
        trust.onChange = { [weak self] trusted in self?.trustChanged(trusted) }
        let engine = engine
        trust.startPolling { await engine.hasParkedWindows() }
        activationObserver = AppActivationObserver(center: activationCenter) { [weak self] in
            self?.trust.refresh()
        }
        await assignments.load()
        try continueStart()
        await layouts.load()
        try continueStart()
        await refreshConfig()
        try continueStart()
        await engine.start()
        try continueStart()
        applyStrip()
        if dragController == nil { dragController = makeDragController?(self) }
        phase = .running
    }

    /// Throws when the start must not go on, after undoing what it did so far.
    func continueStart() throws {
        if phase == .starting, !Task.isCancelled { return }
        if phase == .starting {
            // Cancelled by the caller: this start ends the runtime itself.
            phase = .stopped
            tearDownParts()
            actions.finish()
        }
        throw CancellationError()
    }

    func acquireJournal() async throws {
        for attempt in 0..<2 {
            if let lease = await journal.tryBeginEngine() {
                if phase == .starting, !Task.isCancelled {
                    self.lease = lease
                    return
                }
                // Too late: a stop ran meanwhile, or the caller gave up. The engine never started, so the
                // journal goes back to recovery at once.
                await journal.endEngine(lease)
                if phase == .starting { phase = .stopped }
                throw CancellationError()
            }
            // After the wait the lease is tried again whatever happened meanwhile: one that a stop or a cancel
            // made too late is handed back by the branch above.
            if attempt == 0 { _ = await journal.waitUntilIdle(within: Self.startBudget, clock: context.clock) }
        }
        // A start the caller gave up on (the host's budget) is cancelled, not "still stopping".
        try continueStart()
        throw WindowsPlugin.StartError.stillStopping
    }

    /// Ends every piece a start or a run created that needs no waiting (also called by `stop()`).
    func tearDownParts() {
        activationObserver?.stop()
        activationObserver = nil
        trust.stop()
        dragController?.cancel()
        dragController = nil
        tearDownOverlay()
        strip?.remove()
        strip = nil
        reports.finish()
    }

    /// Puts the windows back and stops, as a whole within `stopBudget`: the wait for the re-grant task and the
    /// queued actions, the restore and the engine's own shutdown all count. What is not done when the budget runs
    /// out stays in the journal, which the old engine keeps until it has really stopped.
    /// - Parameter waitingForTrustTask: `false` when the caller is that task itself (a failed self-check after a
    ///   re-grant stops the runtime from inside it).
    func stop(waitingForTrustTask: Bool = true) async {
        phase = .stopped
        tearDownParts()
        let engine = engine
        let journal = journal
        let lease = lease
        self.lease = nil
        let regrant = trustTask
        trustTask = nil
        regrant?.cancel()
        if let lease { await journal.engineStopping(lease) }
        // A start that is still suspended finishes itself off at its next step (`continueStart`). The engine's own
        // `stop()` is safe either way: a start that comes after it does nothing.
        let actions = actions
        // The journal goes back to recovery only once the engine has really stopped, even when this wait gives
        // up first: a recovery pass must never run beside an engine that still moves windows.
        _ = await withDeadline(Self.stopBudget, clock: context.clock) {
            if waitingForTrustTask { await regrant?.value }
            await actions.waitUntilEmpty()
            // Only the holder of the journal lease stops the engine: its stop restores from the journal and closes
            // the shared store, which would take both from an earlier engine that is still stopping (a start that
            // gave up with `stillStopping` never held the lease and never started its engine).
            if let lease {
                await engine.stop()
                await journal.endEngine(lease)
            }
        }
        // Whatever the budget left queued (or parked in a waiter) is dropped: the queue's task ends with the runtime.
        actions.finish()
    }

}
