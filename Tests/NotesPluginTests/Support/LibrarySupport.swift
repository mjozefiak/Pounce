import Foundation
import LintelKit
import Synchronization

@testable import NotesPlugin

/// A counter a test can wait on without polling: `wait(atLeast:)` returns once `increment()` was called that
/// often, however the two interleave.
final class CountLatch: Sendable {
    private struct State {
        var count = 0
        var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    var count: Int { state.withLock { $0.count } }

    func increment() {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.count += 1
            let count = state.count
            let ready = state.waiters.filter { $0.target <= count }.map(\.continuation)
            state.waiters.removeAll { $0.target <= count }
            return ready
        }
        for continuation in ready { continuation.resume() }
    }

    func wait(atLeast target: Int = 1) async {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state -> Bool in
                if state.count >= target { return true }
                state.waiters.append((target, continuation))
                return false
            }
            if done { continuation.resume() }
        }
    }
}

/// Holds the next calls of a fake source at a point after they took their answer, so a test can change the world
/// and then let the old answer arrive. `release()` lets every held call go on.
final class Gate: Sendable {
    private let state = Mutex<(hold: Int, blocked: [CheckedContinuation<Void, Never>])>((0, []))
    /// How many calls reached the gate and are held.
    let held = CountLatch()

    /// The next `count` calls to `pass()` are held.
    func hold(next count: Int = 1) { state.withLock { $0.hold = count } }

    func pass() async {
        await withCheckedContinuation { continuation in
            let held = state.withLock { state -> Bool in
                guard state.hold > 0 else { return false }
                state.hold -= 1
                state.blocked.append(continuation)
                return true
            }
            if held { self.held.increment() } else { continuation.resume() }
        }
    }

    func release() {
        let all = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            defer { state.blocked = [] }
            return state.blocked
        }
        for continuation in all { continuation.resume() }
    }
}

/// A clock that only moves when a test advances it: the 150 ms budget is tested without waiting.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [UUID: Sleeper] = [:]
        var sleepCalls = 0
    }

    private let state = Mutex(State())
    private let sleeps = CountLatch()
    private let cancelledSleeps = CountLatch()

    /// Returns once `sleep` was asked for `count` times in all; the deadline of the last one is then set.
    func waitForSleeps(_ count: Int) async { await sleeps.wait(atLeast: count) }

    /// Returns once `count` sleeps ended by cancellation. A budget's deadline is cancelled only after its source
    /// answered, so a test that advances the clock waits for it: otherwise the deadline of a source that did answer
    /// could fire first under load and cut it.
    func waitForCancelledSleeps(_ count: Int) async { await cancelledSleeps.wait(atLeast: count) }

    var now: Instant { state.withLock { $0.now } }

    /// How many times `sleep` was asked for, cancelled ones included. A test waits for the sleeps it expects
    /// before it advances time, so the deadline is always set before the clock moves (otherwise a deadline set
    /// after the advance would never fire).
    var sleepCalls: Int { state.withLock { $0.sleepCalls } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    enum Outcome { case wait, fire, cancel }
                    let outcome = state.withLock { state -> Outcome in
                        state.sleepCalls += 1
                        if Task.isCancelled { return .cancel }
                        if deadline <= state.now { return .fire }
                        state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                        return .wait
                    }
                    switch outcome {
                    case .wait: break
                    case .fire: continuation.resume()
                    case .cancel: continuation.resume(throwing: CancellationError())
                    }
                    sleeps.increment()
                }
            } onCancel: {
                let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
                sleeper?.continuation.resume(throwing: CancellationError())
            }
        } catch {
            cancelledSleeps.increment()
            throw error
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            for id in due.keys { state.sleepers.removeValue(forKey: id) }
            return Array(due.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

struct ScriptedError: Error {}

/// A source with scripted pages. `list` pages by an index cursor, newest first as the contract says.
final class ScriptedNoteSource: NoteSource, Sendable {
    enum Behavior: Sendable {
        case answers
        /// Never answers until cancelled.
        case hangs
        case throwsError
    }

    private struct State {
        var items: [NoteSummary]
        var behavior: Behavior = .answers
        var existing: Set<NoteKey>?
        var existsBehavior: Behavior = .answers
        var listCalls = 0
        var existsCalls: [[NoteKey]] = []
        var started = 0
        var contents: [NoteKey: NoteContent] = [:]
        var contentBehavior: Behavior = .answers
        var actions: [NoteSourceAction] = []
        var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
        var listGate: Gate?
        var contentGate: Gate?
        var deleteFails = false
        var onDelete: (@Sendable (NoteKey) -> Void)?
        var renameFails = false
        var renamed: [(NoteKey, String)] = []
    }

    private let listStarts = CountLatch()
    private let existsStarts = CountLatch()
    private let contentStarts = CountLatch()
    private let changeStreamsOpened = CountLatch()
    private let deletes = CountLatch()

    let pluginID: PluginID
    private let state: Mutex<State>

    init(_ pluginID: PluginID, items: [NoteSummary] = []) {
        self.pluginID = pluginID
        state = Mutex(State(items: items.sorted { $0.startedAt > $1.startedAt }))
    }

    var behavior: Behavior {
        get { state.withLock { $0.behavior } }
        set { state.withLock { $0.behavior = newValue } }
    }
    var existsBehavior: Behavior {
        get { state.withLock { $0.existsBehavior } }
        set { state.withLock { $0.existsBehavior = newValue } }
    }
    /// What `exists` knows; `nil` means every key asked about.
    var existing: Set<NoteKey>? {
        get { state.withLock { $0.existing } }
        set { state.withLock { $0.existing = newValue } }
    }
    var items: [NoteSummary] {
        get { state.withLock { $0.items } }
        set { state.withLock { $0.items = newValue.sorted { $0.startedAt > $1.startedAt } } }
    }
    /// What `content(for:)` returns; a key without an entry is "gone" (`nil`).
    var contents: [NoteKey: NoteContent] {
        get { state.withLock { $0.contents } }
        set { state.withLock { $0.contents = newValue } }
    }
    var contentBehavior: Behavior {
        get { state.withLock { $0.contentBehavior } }
        set { state.withLock { $0.contentBehavior = newValue } }
    }
    /// Held at a point after the call took its answer (see `Gate`).
    var listGate: Gate? {
        get { state.withLock { $0.listGate } }
        set { state.withLock { $0.listGate = newValue } }
    }
    var contentGate: Gate? {
        get { state.withLock { $0.contentGate } }
        set { state.withLock { $0.contentGate = newValue } }
    }
    func waitForListStarts(_ count: Int = 1) async { await listStarts.wait(atLeast: count) }
    func waitForExistsStarts(_ count: Int = 1) async { await existsStarts.wait(atLeast: count) }
    func waitForContentStarts(_ count: Int = 1) async { await contentStarts.wait(atLeast: count) }
    func waitForChangeStream(_ count: Int = 1) async { await changeStreamsOpened.wait(atLeast: count) }
    var listCalls: Int { state.withLock { $0.listCalls } }
    var existsCalls: [[NoteKey]] { state.withLock { $0.existsCalls } }
    /// How many `list` calls have begun.
    var started: Int { state.withLock { $0.started } }

    func list(matching: NormalizedQuery?, after: NoteCursor?, limit: Int) async throws -> NotePage {
        let (behavior, all, gate) = state.withLock { state -> (Behavior, [NoteSummary], Gate?) in
            state.listCalls += 1
            state.started += 1
            return (state.behavior, state.items, state.listGate)
        }
        listStarts.increment()
        await gate?.pass()
        switch behavior {
        case .throwsError: throw ScriptedError()
        case .hangs:
            try await Task.sleep(for: .seconds(3600))
            throw ScriptedError()
        case .answers: break
        }
        let matching = matching.map { query in all.filter { ($0.title ?? "").lowercased().contains(query.normalized) } }
        let source = matching ?? all
        let start = after.flatMap { Int($0.token) } ?? 0
        let end = min(source.count, start + limit)
        let page = Array(source[min(start, end)..<end])
        return NotePage(items: page, next: end < source.count ? NoteCursor(token: "\(end)") : nil, total: source.count)
    }

    func exists(_ keys: [NoteKey]) async throws -> Set<NoteKey> {
        let (behavior, known) = state.withLock { state -> (Behavior, Set<NoteKey>?) in
            state.existsCalls.append(keys)
            return (state.existsBehavior, state.existing)
        }
        existsStarts.increment()
        switch behavior {
        case .throwsError: throw ScriptedError()
        case .hangs:
            try await Task.sleep(for: .seconds(3600))
            throw ScriptedError()
        case .answers: break
        }
        return Set(keys).intersection(known ?? Set(keys))
    }

    func content(for key: NoteKey) async throws -> NoteContent? {
        let (behavior, content, gate) = state.withLock { ($0.contentBehavior, $0.contents[key], $0.contentGate) }
        contentStarts.increment()
        await gate?.pass()
        switch behavior {
        case .throwsError: throw ScriptedError()
        case .hangs:
            try await Task.sleep(for: .seconds(3600))
            throw ScriptedError()
        case .answers: return content
        }
    }
    func delete(_ key: NoteKey) async throws {
        deletes.increment()
        let (fails, hook) = state.withLock { ($0.deleteFails, $0.onDelete) }
        hook?(key)
        if fails { throw ScriptedError() }
    }
    /// Makes `delete` throw, like an active meeting or a locked store.
    var deleteFails: Bool {
        get { state.withLock { $0.deleteFails } }
        set { state.withLock { $0.deleteFails = newValue } }
    }
    /// Runs inside `delete`, before it answers: a test looks at what Notes still holds at that moment.
    var onDelete: (@Sendable (NoteKey) -> Void)? {
        get { state.withLock { $0.onDelete } }
        set { state.withLock { $0.onDelete = newValue } }
    }
    var renameFails: Bool {
        get { state.withLock { $0.renameFails } }
        set { state.withLock { $0.renameFails = newValue } }
    }
    var renamedTitles: [(NoteKey, String)] { state.withLock { $0.renamed } }
    /// How many times Notes asked the source to delete a note.
    var deleteCalls: Int { deletes.count }
    /// How many times `content(for:)` was called.
    var contentCalls: Int { contentStarts.count }
    func actions(for key: NoteKey) -> [NoteSourceAction] { state.withLock { $0.actions } }
    func setActions(_ actions: [NoteSourceAction]) { state.withLock { $0.actions = actions } }

    func makeChanges() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { $0.continuations[id] = continuation }
        changeStreamsOpened.increment()
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func signalChange() {
        let all = state.withLock { Array($0.continuations.values) }
        for continuation in all { continuation.yield() }
    }

    var changeStreams: Int { state.withLock { $0.continuations.count } }
}

extension ScriptedNoteSource.Behavior: Equatable {}

extension ScriptedNoteSource: NoteSourceEditing {
    func renameTitle(_ key: NoteKey, to title: String) async throws {
        let fails = state.withLock { state -> Bool in
            state.renamed.append((key, title))
            return state.renameFails
        }
        if fails { throw ScriptedError() }
    }
    func renameSpeaker(_ key: NoteKey, speakerID: String, to name: String) async throws {}
    func markSelf(_ key: NoteKey, speakerID: String) async throws {}
}

/// The overlay store of a library test: both the read port and the detacher, so a detach is visible to the
/// next read. Metadata only.
final class FakeOverlayStore: OverlayIndex, OverlayDetacher, Sendable {
    private struct State {
        var present: [OverlayRecord] = []
        var detached: [OverlayRecord] = []
        var detachCalls: [(key: NoteKey, reason: OverlayDetachReason)] = []
        var failReads = false
        var failDetach = false
    }

    private let state = Mutex(State())

    init(present: [OverlayRecord] = [], detached: [OverlayRecord] = []) {
        state.withLock {
            $0.present = present
            $0.detached = detached
        }
    }

    var detachCalls: [(key: NoteKey, reason: OverlayDetachReason)] { state.withLock { $0.detachCalls } }
    var detachedRecords: [OverlayRecord] { state.withLock { $0.detached } }
    var failReads: Bool {
        get { state.withLock { $0.failReads } }
        set { state.withLock { $0.failReads = newValue } }
    }
    var failDetach: Bool {
        get { state.withLock { $0.failDetach } }
        set { state.withLock { $0.failDetach = newValue } }
    }

    private func read<T>(_ body: (State) -> T) throws -> T {
        try state.withLock { state in
            if state.failReads { throw ScriptedError() }
            return body(state)
        }
    }

    func overlays(for keys: [NoteKey]) async throws -> [OverlayRecord] {
        let wanted = Set(keys)
        return try read { $0.present.filter { $0.sourcePluginID != "notes" && wanted.contains($0.key) } }
    }

    func manualNotes() async throws -> [OverlayRecord] {
        try read { $0.present.filter { $0.sourcePluginID == "notes" } }
    }

    func detachedOverlays() async throws -> [OverlayRecord] { try read { $0.detached } }

    func keptOverlays(excludingPlugins excluding: Set<PluginID>) async throws -> [OverlayRecord] {
        try read {
            $0.present.filter { $0.sourcePluginID != "notes" && $0.isKept && !excluding.contains($0.sourcePluginID) }
        }
    }

    func liveOverlayKeys() async throws -> [NoteKey] {
        try read { state in
            var seen = Set<NoteKey>()
            return state.present.filter { $0.sourcePluginID != "notes" }.map(\.key).filter { seen.insert($0).inserted }
        }
    }

    func detach(_ key: NoteKey, reason: OverlayDetachReason) async throws {
        try state.withLock { state in
            state.detachCalls.append((key, reason))
            if state.failDetach { throw ScriptedError() }
            let moved = state.present.filter { $0.key == key }
            state.present.removeAll { $0.key == key }
            state.detached.append(contentsOf: moved)
        }
    }
}

enum Fixtures {
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func key(_ plugin: PluginID, _ id: String) -> NoteKey { NoteKey(pluginID: plugin, id: id) }

    static func summary(
        _ plugin: PluginID, _ id: String, secondsAgo: Double, title: String? = nil,
        state: NoteState = .ready, kind: NoteKind = .meeting
    ) -> NoteSummary {
        NoteSummary(
            id: key(plugin, id), kind: kind, title: title ?? id, startedAt: epoch.addingTimeInterval(-secondsAgo),
            state: state)
    }

    static func overlay(
        _ doc: Int64, _ key: NoteKey, layer: String, startedAt: Date?, kept: Bool = true, plugin: PluginID? = nil
    ) -> OverlayRecord {
        OverlayRecord(
            docID: doc, key: key, layer: layer, kind: .meeting, sourcePluginID: plugin ?? key.pluginID,
            startedAtMs: startedAt.map(NoteTime.milliseconds), createdAt: epoch, updatedAt: epoch, isKept: kept)
    }

    static func manual(_ doc: Int64, _ id: String, secondsAgo: Double, title: String) -> OverlayRecord {
        OverlayRecord(
            docID: doc, key: key("notes", id), layer: "body", kind: .manual, sourcePluginID: "notes", title: title,
            createdAt: epoch.addingTimeInterval(-secondsAgo), updatedAt: epoch, isKept: true)
    }
}

/// The sources a library test hands over, changeable like the shell's set of active plugins.
final class SourceBox: Sendable {
    private let value: Mutex<[any NoteSource]>
    init(_ sources: [any NoteSource]) { value = Mutex(sources) }
    var sources: [any NoteSource] {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

extension NoteLibrary {
    init(
        box: SourceBox, store: FakeOverlayStore = FakeOverlayStore(), clock: any Clock<Duration> = ManualClock()
    ) {
        self.init(sources: { box.sources }, overlays: store, detacher: store, clock: clock)
    }
}
