import CoreGraphics
import Foundation
import LintelKit
import os

/// Where the engine reports what the user should see. Called from the engine's actor; each closure must be quick
/// (the runtime puts every report on one ordered stream).
struct EngineReporter: Sendable {
    var hud: @Sendable (_ workspace: WorkspaceID, _ windowCount: Int) -> Void = { _, _ in }
    var summary: @Sendable (WorkspaceSummary) -> Void = { _ in }
    var banner: @Sendable (EngineBanner) -> Void = { _ in }
    /// A managed window of a workspace whose layout has snap targets was moved by the user (or an app): the snap
    /// overlay's detector samples the pointer.
    var windowMoved: @Sendable (WindowID, CGRect) -> Void = { _, _ in }
    /// Windows came back without a command asking for it (a Space change showed journal entries again).
    var restored: @Sendable (RecoveryReport) -> Void = { _ in }
}

/// Carries out the effects the reducer returned, against a `WindowClient` and the `StateStore`. It decides
/// nothing: effects go to lanes (one per process for frame changes and focus, one for the journal and the stored
/// state) and every result goes back to the engine through `Callbacks`.
struct EffectExecutor {
    enum Lane: Hashable, Sendable {
        case process(Int32)
        case store
    }

    /// How the executor talks back to the engine (all hop onto its actor).
    struct Callbacks: Sendable {
        /// A frame change is about to be sent to the app: the engine stamps its echo window now, not when the
        /// change was only queued.
        var started: @Sendable (FrameRequest) async -> Void
        /// Whether a request is still the newest for its window; an older one waiting its turn is dropped.
        var isCurrent: @Sendable (FrameRequest) async -> Bool
        /// One piece of work finished, with the frame result to reduce, if it had one.
        var finished: @Sendable (_ batch: Int, _ result: FrameResult?) async -> Void
    }

    /// What dispatching handed to the lanes, and what the engine must reduce next.
    struct Dispatch {
        var operations = 0
        var inputs: [EngineInput] = []
    }

    private let client: any WindowClient
    private let store: StateStore
    private let reporter: EngineReporter
    private let strategies: LayoutRegistry
    private let scheduler = LaneScheduler<Lane>()
    private let logger: Logger
    private var watchdog: Watchdog

    init(
        client: any WindowClient, store: StateStore, reporter: EngineReporter, strategies: LayoutRegistry,
        watchdog: Watchdog, logger: Logger
    ) {
        self.client = client
        self.store = store
        self.reporter = reporter
        self.strategies = strategies
        self.watchdog = watchdog
        self.logger = logger
    }

    /// - Parameter trusted: whether windows may be moved at all (Accessibility). When not, every frame change
    ///   fails as `.notTrusted`, which the reducer answers by keeping a parked window parked and a window that was
    ///   meant to be parked where it is; nothing is focused or journaled.
    mutating func dispatch(
        _ effects: [EngineEffect], batch: Int, now: Double, trusted: Bool, callbacks: Callbacks
    ) -> Dispatch {
        var plan = Dispatch()
        var journalEntries: [HiddenEntry] = []
        var requests: [FrameRequest] = []
        var removals = Set<WindowID>()
        var others: [EngineEffect] = []
        for effect in effects {
            switch effect {
            case .journalPark(let entries): journalEntries.append(contentsOf: entries)
            case .setFrame(let request): requests.append(request)
            case .journalRemove(let ids): removals.formUnion(ids)
            default: others.append(effect)
            }
        }
        guard trusted else {
            let failed = requests.map { FrameResult(request: $0, outcome: .failed(.notTrusted)) }
            if !failed.isEmpty { plan.inputs.append(.applied(failed, now: now)) }
            if !removals.isEmpty { plan.operations += removeFromJournal(removals, batch: batch, callbacks) }
            for effect in others {
                switch effect {
                case .focus, .userMovedWindow: break
                default: plan.operations += perform(effect, batch: batch, callbacks)
                }
            }
            return plan
        }
        var journal: OneShot<Set<WindowID>>?
        if !journalEntries.isEmpty {
            let gate = OneShot<Set<WindowID>>()
            journal = gate
            plan.operations += writeJournal(journalEntries, gate: gate, batch: batch, callbacks)
        }
        var tripped = false
        for request in requests {
            // Restoring is the way out of a fight, so it is never counted: the watchdog must not stop itself.
            if request.purpose != .restore, watchdog.record(now: now) {
                tripped = true
                break
            }
            plan.operations += setFrame(request, journal: journal, batch: batch, callbacks)
        }
        if tripped {
            watchdog.reset()
            plan.inputs.append(.watchdogTripped(now: now))
        }
        if !removals.isEmpty { plan.operations += removeFromJournal(removals, batch: batch, callbacks) }
        for effect in others { plan.operations += perform(effect, batch: batch, callbacks) }
        return plan
    }

    // MARK: Pieces

    private func writeJournal(
        _ entries: [HiddenEntry], gate: OneShot<Set<WindowID>>, batch: Int, _ callbacks: Callbacks
    ) -> Int {
        let store = store
        scheduler.run(
            on: .store,
            work: { () -> Set<WindowID> in
                do {
                    try await store.addHidden(entries)
                    return []
                } catch {
                    return Set(entries.map(\.windowID))
                }
            },
            then: { blocked in
                gate.set(blocked)
                await callbacks.finished(batch, nil)
            })
        return 1
    }

    private func removeFromJournal(_ ids: Set<WindowID>, batch: Int, _ callbacks: Callbacks) -> Int {
        let store = store
        let logger = logger
        scheduler.run(
            on: .store,
            work: {
                do { try await store.removeHidden(ids) } catch { logger.error("Cannot clear the journal") }
            },
            then: { await callbacks.finished(batch, nil) })
        return 1
    }

    private func setFrame(
        _ request: FrameRequest, journal: OneShot<Set<WindowID>>?, batch: Int, _ callbacks: Callbacks
    ) -> Int {
        let client = client
        scheduler.run(
            on: .process(request.id.pid),
            work: { () -> FrameResult? in
                if request.purpose == .park, let journal, await journal.wait().contains(request.id) {
                    return FrameResult(request: request, outcome: .blocked)
                }
                // A newer request for this window was reduced while this one waited its turn: it is dropped.
                guard await callbacks.isCurrent(request) else { return nil }
                await callbacks.started(request)
                do throws(WindowClientError) {
                    let actual = try await client.setFrame(request.frame, for: request.id)
                    return FrameResult(request: request, outcome: .applied(actual))
                } catch {
                    return FrameResult(request: request, outcome: .failed(error))
                }
            },
            then: { await callbacks.finished(batch, $0) })
        return 1
    }

    private func perform(_ effect: EngineEffect, batch: Int, _ callbacks: Callbacks) -> Int {
        let store = store
        switch effect {
        case .focus(let id):
            let client = client
            scheduler.run(
                on: .process(id.pid), work: { try? await client.focus(id) },
                then: { await callbacks.finished(batch, nil) })
            return 1
        case .saveOrder(let order):
            scheduler.run(
                on: .store, work: { await store.setOrder(order) }, then: { await callbacks.finished(batch, nil) })
            return 1
        case .saveLayouts(let layouts):
            let encoded = strategies.encode(layouts)
            scheduler.run(
                on: .store, work: { await store.setLayouts(encoded) },
                then: { await callbacks.finished(batch, nil) })
            return 1
        case .userMovedWindow(let id, let frame):
            reporter.windowMoved(id, frame)
        case .hud(let workspace, let count):
            reporter.hud(workspace, count)
        case .summaryChanged(let summary):
            reporter.summary(summary)
        case .banner(let banner):
            reporter.banner(banner)
        case .journalPark, .journalRemove, .setFrame:
            break
        }
        return 0
    }
}
