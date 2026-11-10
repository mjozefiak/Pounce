import Foundation
import LintelSpeech
import Synchronization
import Testing

@testable import NotesPlugin

/// A gate a test opens: `wait()` returns when it is opened and throws `CancellationError` when the waiting task is
/// cancelled first. No time involved.
final class ReviseGate: Sendable {
    private struct State {
        var open = false
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())
    let waiting = CountLatch()

    func open() {
        let all = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.open = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in all { waiter.resume() }
    }

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case wait, go, cancel }
                let outcome = state.withLock { state -> Outcome in
                    if state.open { return .go }
                    if Task.isCancelled { return .cancel }
                    state.waiters[id] = continuation
                    return .wait
                }
                switch outcome {
                case .go: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: waiting.increment()
                }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

/// One scripted lease handle: every `generate` call takes the next behaviour.
final class ScriptedReviseHandle: ReviseModelHandle, Sendable {
    enum Behavior: Sendable {
        case answer(String)
        /// A cut-off answer.
        case truncated(String)
        case yielded
        /// Never answers until cancelled.
        case hang
        /// Waits for the gate, then answers.
        case after(ReviseGate, String)
    }

    private struct State {
        var script: [Behavior]
        var prompts: [[ChatMessage]] = []
        var released = 0
    }

    private let state: Mutex<State>
    /// Incremented when a generation starts (a test waits for it before it acts on a running generation).
    let generating = CountLatch()

    init(_ script: [Behavior]) {
        state = Mutex(State(script: script))
    }

    var prompts: [[ChatMessage]] { state.withLock { $0.prompts } }
    var releases: Int { state.withLock { $0.released } }

    func generate(messages: [ChatMessage], maxTokens: Int) async throws -> GenerationResult {
        let behavior = state.withLock { state -> Behavior? in
            state.prompts.append(messages)
            return state.script.isEmpty ? nil : state.script.removeFirst()
        }
        generating.increment()
        switch behavior {
        case .answer(let text)?: return GenerationResult(text: text, stoppedByTokenLimit: false)
        case .truncated(let text)?: return GenerationResult(text: text, stoppedByTokenLimit: true)
        case .yielded?: throw ModelLeaseError.yielded
        case .hang?:
            let never = ReviseGate()
            try await never.wait()
            throw CancellationError()
        case .after(let gate, let text)?:
            try await gate.wait()
            return GenerationResult(text: text, stoppedByTokenLimit: false)
        case nil: throw ScriptedError()
        }
    }

    func release() async { state.withLock { $0.released += 1 } }
}

/// A lease whose `acquire` follows a script: busy, a handle, or an error. `acquires` counts the calls.
final class ScriptedReviseLease: ReviseModelLeasing, Sendable {
    enum Step: Sendable {
        case busy
        case handle(ScriptedReviseHandle)
        case fail
        /// Waits for the gate, then hands out the handle.
        case after(ReviseGate, ScriptedReviseHandle)
    }

    private let script: Mutex<[Step]>
    let acquires = CountLatch()

    init(_ steps: [Step]) {
        script = Mutex(steps)
    }

    func acquire() async throws -> any ReviseModelHandle {
        let step = script.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        acquires.increment()
        switch step {
        case .busy?: throw ModelLeaseError.busy
        case .handle(let handle)?: return handle
        case .after(let gate, let handle)?:
            try await gate.wait()
            return handle
        case .fail?, nil: throw ScriptedError()
        }
    }
}

/// A store with one seeded note that carries the comments, a writer, a lock and a service on the injected clock.
@MainActor
final class ReviseRig {
    let rig: DocRig
    let writer: RevisionWriter
    let lock = EditLock()
    let item: NoteItemID
    let comments: CommentService
    let service: ReviseService
    let lease: ScriptedReviseLease
    var docID: Int64 = 0

    static let note = ReviseFixtures.note

    init(steps: [ScriptedReviseLease.Step], modelInstalled: Bool = true, maxYields: Int = 20) throws {
        rig = try DocRig()
        item = .live(rig.meeting)
        let lease = ScriptedReviseLease(steps)
        self.lease = lease
        writer = rig.writer(.seed(try rig.plan(rig.layer(Self.note))))
        comments = CommentService(store: rig.store, now: { Date(timeIntervalSince1970: 1_800_000_100) })
        var deps = ReviseService.Dependencies(
            clock: RunClock(rig.clock),
            model: { modelInstalled ? ResolvedReviseModel(id: "qwen3-test", leasing: lease) : nil })
        deps.log = rig.log
        deps.maxYields = maxYields
        deps.now = { Date(timeIntervalSince1970: 1_800_000_200) }
        service = ReviseService(deps)
    }

    /// Comments on `quote`; the first call seeds the overlay.
    @discardableResult
    func comment(_ quote: String, body: String = "Add an owner.") async throws -> Int64 {
        let text = Self.note as NSString
        let thread = try await comments.add(
            body: body, selection: text.range(of: quote), buffer: Self.note, writer: writer)
        docID = try await writer.ensureDocument().docID
        return thread
    }

    func request(threads: Set<Int64>? = nil) -> ReviseRequest {
        ReviseRequest(item: item, writer: writer, lock: lock, store: rig.store, threads: threads)
    }

    func head() throws -> RevisionRecord { try rig.head(docID) }

    func openThreads() throws -> Int {
        CommentThreads.group(try rig.store.comments(of: docID)).filter(\.isOpen).count
    }

    /// The model's answer for one commented block.
    static func unit(_ text: String) -> String { "[[unit 1]]\n\(text)" }
}
