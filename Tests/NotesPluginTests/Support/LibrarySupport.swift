import Foundation
import LintelKit
import Synchronization

@testable import NotesPlugin

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
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case wait, fire, cancel }
                let outcome = state.withLock { state -> Outcome in
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
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
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
        var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

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
    var listCalls: Int { state.withLock { $0.listCalls } }
    var existsCalls: [[NoteKey]] { state.withLock { $0.existsCalls } }
    /// How many `list` calls have begun.
    var started: Int { state.withLock { $0.started } }

    func list(matching: NormalizedQuery?, after: NoteCursor?, limit: Int) async throws -> NotePage {
        let (behavior, all) = state.withLock { state -> (Behavior, [NoteSummary]) in
            state.listCalls += 1
            state.started += 1
            return (state.behavior, state.items)
        }
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
        switch behavior {
        case .throwsError: throw ScriptedError()
        case .hangs:
            try await Task.sleep(for: .seconds(3600))
            throw ScriptedError()
        case .answers: break
        }
        return Set(keys).intersection(known ?? Set(keys))
    }

    func content(for key: NoteKey) async throws -> NoteContent? { nil }
    func delete(_ key: NoteKey) async throws {}
    func actions(for key: NoteKey) -> [NoteSourceAction] { [] }

    func makeChanges() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { $0.continuations[id] = continuation }
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
