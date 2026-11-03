import Foundation
import Synchronization

/// The language-model twin of `SpeechEngineLease`: key `(model id, context length)` (dictation 4096, notes
/// 8192), at most one model resident, `busy` for another key while a lease is active, the keep-warm time from
/// the last release. Generation goes through one queue, `interactive` first; a `background` generation that is
/// running is cancelled between two tokens when an `interactive` request arrives and starts over after it.
///
/// An `interactive` request for the same model file under another key (dictation's 4096 against the notes'
/// 8192) does not get `busy` while the holders are `background`: the background leases are asked to yield (their
/// generation is cancelled between two tokens and the lease is given back), the model is reloaded under the
/// interactive key (one copy in memory at any time) and the background handle reports `ModelLeaseError.yielded`,
/// so its owner takes a new lease after the interactive one is released and repeats the interrupted request.
/// A different model file is never taken away: that is still `busy`.
public final class LLMLease: Sendable {
    public static let shared = LLMLease()

    public struct Key: Hashable, Sendable {
        public let modelID: String
        public let contextLength: Int

        public init(modelID: String, contextLength: Int) {
            self.modelID = modelID
            self.contextLength = contextLength
        }
    }

    private let residency: Residency<Key, Held<any LLMRuntime>>
    private let turnstile = Turnstile()
    private let registry = Mutex(Registry())

    private struct Registry {
        /// Background leases that exist (pending, held), so an interactive request can ask them to yield.
        var background: [ObjectIdentifier: LeaseTicket] = [:]
        /// Model files an interactive request is taking over right now: no background request takes one back.
        var takingOver: [String: Int] = [:]
    }

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        residency = Residency(
            ops: .init(
                isLoaded: { await $0.base.isLoaded },
                unload: { held in
                    await held.inFlight.idle()
                    await held.base.unload()
                }), sleep: sleep)
    }

    /// Takes a lease on the model. When `key` is resident its runtime is shared and `runtime` is ignored;
    /// otherwise `runtime` loads `modelURL` (after an idle resident model is unloaded). An `interactive` request
    /// takes the model over from `background` leases of the same file (see the type's comment).
    public func acquire(
        key: Key, runtime: any LLMRuntime, modelURL: URL, priority: LeasePriority,
        keepWarm: @escaping @Sendable () -> Duration
    ) async throws -> LLMHandle {
        let ticket = LeaseTicket(key: key, priority: priority, keepWarm: keepWarm)
        if priority == .background {
            let refused = registry.withLock { registry -> Bool in
                if registry.takingOver[key.modelID, default: 0] > 0 { return true }
                registry.background[ObjectIdentifier(ticket)] = ticket
                return false
            }
            if refused { throw ModelLeaseError.busy }
        }
        let held = Held(runtime)
        let load: @Sendable (Held<any LLMRuntime>) async throws -> Void = { try await $0.base.load(modelAt: modelURL) }
        let shared: Held<any LLMRuntime>
        do {
            shared = try await take(key: key, held: held, priority: priority, load: load)
        } catch {
            await forget(ticket)
            throw error
        }
        let yieldedAlready = ticket.markHeld()
        let handle = LLMHandle(owner: self, ticket: ticket, runtime: shared)
        if yieldedAlready { await giveBack(ticket) }
        return handle
    }

    private func take(
        key: Key, held: Held<any LLMRuntime>, priority: LeasePriority,
        load: @escaping @Sendable (Held<any LLMRuntime>) async throws -> Void
    ) async throws -> Held<any LLMRuntime> {
        do {
            return try await residency.acquire(key: key, model: held, load: load)
        } catch ModelLeaseError.busy where priority == .interactive {
            guard !yieldingVictims(of: key).isEmpty else { throw ModelLeaseError.busy }
        }
        registry.withLock { $0.takingOver[key.modelID, default: 0] += 1 }
        defer {
            registry.withLock { registry in
                registry.takingOver[key.modelID, default: 1] -= 1
                if registry.takingOver[key.modelID] == 0 { registry.takingOver[key.modelID] = nil }
            }
        }
        while true {
            let victims = yieldingVictims(of: key)
            for victim in victims { await yield(victim) }
            do {
                return try await residency.acquire(key: key, model: held, load: load)
            } catch ModelLeaseError.busy {
                if victims.isEmpty { throw ModelLeaseError.busy }
            }
        }
    }

    /// Background leases of the same model file under another key.
    private func yieldingVictims(of key: Key) -> [LeaseTicket] {
        registry.withLock { registry in
            registry.background.values.filter { $0.key.modelID == key.modelID && $0.key != key }
        }
    }

    /// Asks the ticket's holder to stop: its generation is cancelled, its lease is given back, and this returns
    /// when that is done (a lease that is still loading is given back as soon as the load ends).
    private func yield(_ ticket: LeaseTicket) async {
        if ticket.requestYield() { await giveBack(ticket) }
        await ticket.whenFinished()
    }

    private func forget(_ ticket: LeaseTicket) async {
        registry.withLock { _ = $0.background.removeValue(forKey: ObjectIdentifier(ticket)) }
        ticket.abandon()
    }

    /// Unloads the model now when no lease is active. Returns when it is unloaded.
    public func evictIdle() async {
        await residency.evictIdle()
    }

    public var residentKey: Key? {
        get async { await residency.residentKey }
    }

    public var activeLeases: Int {
        get async { await residency.activeLeases }
    }

    /// Whether any lease is active on the model file `modelID` (its path), whatever the context length.
    public func isInUse(modelID: String) async -> Bool {
        await residency.leases(where: { $0.modelID == modelID }) > 0
    }

    /// Generations waiting for their turn.
    var queued: Int { turnstile.waiting }

    /// Gives the ticket's lease back once (a release after a yield does nothing more).
    fileprivate func giveBack(_ ticket: LeaseTicket) async {
        if ticket.takeLease() {
            await residency.release(key: ticket.key, keepWarm: ticket.keepWarm())
        }
        registry.withLock { _ = $0.background.removeValue(forKey: ObjectIdentifier(ticket)) }
        ticket.finish()
    }

    fileprivate func generate(
        _ held: Held<any LLMRuntime>, ticket: LeaseTicket, messages: [ChatMessage], maxTokens: Int,
        onPhase: (@Sendable (GenerationPhase) -> Void)?
    ) async throws -> GenerationResult {
        let priority = ticket.priority
        // Already counted by the handle; the model is not unloaded before this call returns.
        defer { held.inFlight.end() }
        let runtime = held.base
        while true {
            if ticket.yieldRequested { throw ModelLeaseError.yielded }
            let preemption = Preemption()
            ticket.setPreemption(preemption)
            defer { ticket.setPreemption(nil) }
            onPhase?(.queued)
            try await turnstile.enter(priority, preempt: { preemption.fire() })
            if ticket.yieldRequested {
                turnstile.leave()
                throw ModelLeaseError.yielded
            }
            onPhase?(.running)
            let run = Task { try await runtime.generateResult(messages: messages, maxTokens: maxTokens) }
            preemption.attach(run)
            let result = await withTaskCancellationHandler {
                await run.result
            } onCancel: {
                run.cancel()
            }
            turnstile.leave()
            onPhase?(.queued)
            switch result {
            case .success(let value):
                return value
            case .failure(let error):
                // Stopped for an interactive request, not by the caller: wait for the turn again.
                if error is CancellationError, preemption.fired, !Task.isCancelled {
                    if ticket.yieldRequested { throw ModelLeaseError.yielded }
                    continue
                }
                throw error
            }
        }
    }
}

/// Lets the turnstile cancel a generation that may not have started yet.
final class Preemption: Sendable {
    private struct State {
        var fired = false
        var task: Task<GenerationResult, any Error>?
    }

    private let state = Mutex(State())

    var fired: Bool { state.withLock { $0.fired } }

    func attach(_ task: Task<GenerationResult, any Error>) {
        let cancelNow = state.withLock { state -> Bool in
            state.task = task
            return state.fired
        }
        if cancelNow { task.cancel() }
    }

    func fire() {
        let task = state.withLock { state -> Task<GenerationResult, any Error>? in
            state.fired = true
            return state.task
        }
        task?.cancel()
    }
}

/// Where a request of a lease is: waiting for its turn, or generating.
public enum GenerationPhase: Sendable, Equatable {
    case queued, running
}

public final class LLMHandle: Sendable {
    public let key: LLMLease.Key
    public let priority: LeasePriority
    private let owner: LLMLease
    private let ticket: LeaseTicket
    private let runtime: Held<any LLMRuntime>
    private let released = Mutex(false)

    fileprivate init(owner: LLMLease, ticket: LeaseTicket, runtime: Held<any LLMRuntime>) {
        self.owner = owner
        self.ticket = ticket
        self.key = ticket.key
        self.priority = ticket.priority
        self.runtime = runtime
    }

    /// `onPhase` reports `.queued` while the request waits for its turn (and again after a preemption) and
    /// `.running` while the model generates, so a caller can time only the generation. Throws
    /// `ModelLeaseError.yielded` when an `interactive` request took the model over from this `background`
    /// lease: the lease is gone, the caller takes a new one later and repeats the request.
    public func generateResult(
        messages: [ChatMessage], maxTokens: Int, onPhase: (@Sendable (GenerationPhase) -> Void)? = nil
    ) async throws -> GenerationResult {
        let allowed = released.withLock { released -> Bool in
            guard !released else { return false }
            runtime.inFlight.begin()
            return true
        }
        guard allowed else { throw ModelLeaseError.released }
        return try await owner.generate(
            runtime, ticket: ticket, messages: messages, maxTokens: maxTokens, onPhase: onPhase)
    }

    /// Whether the lease was taken away for an `interactive` request (every request now throws `yielded`).
    public var wasYielded: Bool { ticket.yieldRequested }

    public func release() async {
        let wasReleased = released.withLock { state -> Bool in
            let was = state
            state = true
            return was
        }
        guard !wasReleased else { return }
        await owner.giveBack(ticket)
    }
}

/// One lease of an `LLMLease`: whether it is held, and whether its holder was asked to give it up.
final class LeaseTicket: Sendable {
    let key: LLMLease.Key
    let priority: LeasePriority
    let keepWarm: @Sendable () -> Duration

    private enum Lease { case pending, held, gone }

    private struct State {
        var lease = Lease.pending
        var yieldRequested = false
        var preemption: Preemption?
        var finished = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    init(key: LLMLease.Key, priority: LeasePriority, keepWarm: @escaping @Sendable () -> Duration) {
        self.key = key
        self.priority = priority
        self.keepWarm = keepWarm
    }

    var yieldRequested: Bool { state.withLock { $0.yieldRequested } }

    func setPreemption(_ preemption: Preemption?) {
        let fire = state.withLock { state -> Bool in
            state.preemption = preemption
            return preemption != nil && state.yieldRequested
        }
        if fire { preemption?.fire() }
    }

    /// The lease is loaded and held. True when a yield was requested meanwhile (the caller gives it back).
    func markHeld() -> Bool {
        state.withLock { state in
            if state.lease == .pending { state.lease = .held }
            return state.yieldRequested
        }
    }

    /// Asks the holder to stop; true when the lease is held and the caller must give it back.
    func requestYield() -> Bool {
        let (preemption, held) = state.withLock { state -> (Preemption?, Bool) in
            state.yieldRequested = true
            return (state.preemption, state.lease == .held)
        }
        preemption?.fire()
        return held
    }

    /// True once: the caller that gets it releases the lease in the residency.
    func takeLease() -> Bool {
        state.withLock { state in
            guard state.lease == .held else { return false }
            state.lease = .gone
            return true
        }
    }

    /// The load failed: no lease exists.
    func abandon() {
        state.withLock { $0.lease = .gone }
        finish()
    }

    func finish() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.finished = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func whenFinished() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = state.withLock { state -> Bool in
                if state.finished { return true }
                state.waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }
}
