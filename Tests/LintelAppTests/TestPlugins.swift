import AppKit
import Foundation
import LintelKit
import Synchronization

@testable import LintelApp

/// Records lifecycle calls of the test plugins. Only touched on the main actor.
@MainActor
final class LifecycleLog {
    static let shared = LifecycleLog()
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func reset() {
        events = []
    }
}

enum TestError: Error {
    case activationFailed
    case searchFailed
    case eraseFailed
}

/// Answers immediately with one candidate.
struct InstantSource: SearchSource {
    let id: SourceID

    func search(_ query: NormalizedQuery, limit: Int) async throws -> [Candidate] {
        [
            Candidate(
                itemKey: ItemKey(pluginID: "alpha", key: query.normalized),
                title: "Result for \(query.raw)",
                icon: .symbol("circle"),
                match: MatchResult(tier: .exact, score: 1)
            )
        ]
    }
}

/// Never answers and ignores cancellation until the test lets it go, like a source stuck in blocking work.
struct StuckSource: SearchSource {
    let id: SourceID = "stuck"

    let gate: Gate

    func search(_ query: NormalizedQuery, limit: Int) async throws -> [Candidate] {
        let gate = gate
        await Task.detached { await gate.wait() }.value
        return []
    }
}

/// Lets every waiter, now and later, go once opened.
nonisolated final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func open() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for waiter in waiting { waiter.resume() }
    }

    func reset() { state.withLock { $0.isOpen = false } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let proceed = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiting.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
    }
}

/// A clock whose sleeps end at once: a deadline on it has passed as soon as it is awaited, so a test needs no real
/// time to see a bound fire.
nonisolated final class ExpiredClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

/// Simulates blocking work that never checks for cancellation.
nonisolated func blockCurrentThread(microseconds: UInt32) {
    usleep(microseconds)
}

/// Fails every query.
struct ThrowingSource: SearchSource {
    let id: SourceID = "throwing"

    func search(_ query: NormalizedQuery, limit: Int) async throws -> [Candidate] {
        throw TestError.searchFailed
    }
}

final class AlphaPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "alpha", displayName: "Alpha", symbolName: "a.circle", order: 1)

    init(context: PluginContext) {}

    func activate() async throws { LifecycleLog.shared.record("alpha.activate") }
    func deactivate() async { LifecycleLog.shared.record("alpha.deactivate") }

    var searchSources: [any SearchSource] { [InstantSource(id: "alpha.instant")] }
    var commands: [PluginCommand] {
        [PluginCommand(id: "alpha.open", title: "Open Alpha") { LifecycleLog.shared.record("alpha.command") }]
    }
}

final class BetaPlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "beta",
        displayName: "Beta",
        symbolName: "b.circle",
        order: 2,
        defaultEnabled: false
    )

    init(context: PluginContext) {}

    func activate() async throws { LifecycleLog.shared.record("beta.activate") }
    func deactivate() async { LifecycleLog.shared.record("beta.deactivate") }

    var commands: [PluginCommand] {
        [PluginCommand(id: "beta.open", title: "Open Beta") {}]
    }
}

final class FailingPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "failing", displayName: "Failing", symbolName: "x.circle", order: 0)

    init(context: PluginContext) {}

    func activate() async throws {
        LifecycleLog.shared.record("failing.activate")
        throw TestError.activationFailed
    }

    func deactivate() async { LifecycleLog.shared.record("failing.deactivate") }

    var searchSources: [any SearchSource] { [InstantSource(id: "failing.instant")] }
    var commands: [PluginCommand] {
        [PluginCommand(id: "failing.open", title: "Open Failing") {}]
    }
}

final class StuckPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "stuck", displayName: "Stuck", symbolName: "tortoise", order: 3)

    private let gate: Gate

    init(context: PluginContext) {
        gate = context.services.value(StuckGateKey.self, for: context)
    }

    var searchSources: [any SearchSource] { [StuckSource(gate: gate), ThrowingSource()] }
}

/// Keeps data in the Keychain and its storage directory, to test "Erase Data".
final class StorageWritingPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "storage", displayName: "Storage", symbolName: "tray", order: 4)

    private let context: PluginContext

    init(context: PluginContext) {
        self.context = context
    }

    func activate() async throws {
        LifecycleLog.shared.record("storage.activate")
        let file = context.storageDirectory.appending(path: "data.bin")
        try Data("x".utf8).write(to: file)
        if (try? context.keychain.readGenericPassword(service: "storage", account: "key")) == nil {
            try context.keychain.addGenericPassword(Data("k".utf8), service: "storage", account: "key")
        }
    }

    func eraseData() async throws {
        LifecycleLog.shared.record("storage.erase")
        try context.keychain.deleteGenericPassword(service: "storage", account: "key")
    }
}

/// A fresh, isolated environment per test: temporary data root, in-memory settings and Keychain, and
/// a private pasteboard. Nothing is written to a `UserDefaults` domain.
struct TestEnvironment {
    let environment: AppEnvironment
    let settings: InMemorySettingsStore

    init() throws {
        QuietMeetings.install()
        let name = "lintel-app-tests-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        try AppEnvironment.createPrivateDirectory(root, fileManager: .default)
        settings = InMemorySettingsStore()
        environment = AppEnvironment(
            dataRoot: root,
            cachesRoot: root.appending(path: "Caches", directoryHint: .isDirectory),
            settings: settings,
            keychain: InMemoryKeychainClient(),
            pasteboardName: NSPasteboard.Name(name),
            usage: InMemoryUsageRecorder(),
            registersGlobalHotkeys: false
        )
    }

    func makeHost(
        _ types: [any LintelPlugin.Type],
        budget: Duration = .milliseconds(150),
        recoveryBudget: Duration = .seconds(5),
        activationBudget: Duration = .seconds(20),
        clock: any Clock<Duration> = ContinuousClock()
    ) -> PluginHost {
        PluginHost(
            pluginTypes: types,
            makeContext: { environment.makeContext(for: $0) },
            settings: settings,
            sourceBudget: budget,
            recoveryBudget: recoveryBudget,
            activationBudget: activationBudget,
            clock: clock
        )
    }

    /// The scripted answers of `LaunchRecoveryPlugin` in this environment.
    var recoveryScript: RecoveryScript {
        environment.services.value(
            RecoveryScriptKey.self, for: environment.makeContext(for: LaunchRecoveryPlugin.manifest))
    }

    /// What `OverrunRecoveryPlugin` shares with the test.
    var overrun: OverrunControl {
        environment.services.value(
            OverrunControlKey.self, for: environment.makeContext(for: OverrunRecoveryPlugin.manifest))
    }

    func tearDown() {
        environment.services.value(StuckGateKey.self, for: environment.makeContext(for: StuckPlugin.manifest)).open()
        overrun.gate.open()
        try? FileManager.default.removeItem(at: environment.dataRoot)
    }
}

/// Cannot erase its data, to test how "Erase Data" reports a failure.
final class UnerasablePlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "unerasable", displayName: "Unerasable", symbolName: "lock", order: 5)

    init(context: PluginContext) {}

    func eraseData() async throws {
        throw TestError.eraseFailed
    }
}

/// Refuses to erase, like a plugin whose data may still be needed: the host must keep the data and the plugin on.
final class RefusingErasePlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "refusing", displayName: "Refusing", symbolName: "lock", order: 5)

    init(context: PluginContext) {}

    func activate() async throws { LifecycleLog.shared.record("refusing.activate") }
    func deactivate() async { LifecycleLog.shared.record("refusing.deactivate") }
    func eraseData() async throws { throw TestError.eraseFailed }
}

/// Records `recoverAtLaunch` calls and answers with a scripted outcome, enabled or not.
final class LaunchRecoveryPlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "launchrecovery", displayName: "Launch recovery", symbolName: "arrow.uturn.backward", order: 6,
        defaultEnabled: false)

    init(context: PluginContext) {}

    nonisolated static func recoverAtLaunch(context: PluginContext) async -> RecoveryOutcome {
        context.services.value(RecoveryScriptKey.self, for: context).next()
    }
}

/// The scripted answers of `LaunchRecoveryPlugin`; the last one repeats. Thread-safe because the host calls
/// `recoverAtLaunch` off the main actor.
nonisolated final class RecoveryScript: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [RecoveryOutcome] = [.done]
    private var calls = 0

    func reset(_ answers: [RecoveryOutcome]) {
        lock.lock()
        defer { lock.unlock() }
        self.answers = answers
        calls = 0
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func next() -> RecoveryOutcome {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return answers[min(calls, answers.count) - 1]
    }
}

/// What `OverrunRecoveryPlugin` shares with its test through the context's services: how often it was entered and
/// the gate that holds it.
nonisolated final class OverrunControl: Sendable {
    let entered = Mutex(0)
    let gate = Gate()
}

/// A `recoverAtLaunch` that ignores its bound and cancellation until the test opens the gate, and counts how often it
/// was entered. Nothing here depends on how long the test takes, so a busy machine cannot finish it early.
final class OverrunRecoveryPlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "overrunrecovery", displayName: "Overrun recovery", symbolName: "tortoise", order: 7,
        defaultEnabled: false)

    init(context: PluginContext) {}

    nonisolated static func recoverAtLaunch(context: PluginContext) async -> RecoveryOutcome {
        let control = context.services.value(OverrunControlKey.self, for: context)
        control.entered.withLock { $0 += 1 }
        await control.gate.wait()
        return .done
    }
}

/// A clock that moves only when the test advances it; `waitForSleepers(atLeast:)` lets a test wait for the tasks that
/// are to sleep on it, without any real time.
nonisolated final class GatedClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [UInt64: Sleeper] = [:]
        var atLeastWaiters: [(count: Int, continuation: CheckedContinuation<Bool, Never>)] = []
        var next: UInt64 = 0
        var finished = false
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let id = state.withLock { state -> UInt64 in
            state.next += 1
            return state.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    let ready = state.atLeastWaiters.filter { $0.count <= state.sleepers.count }.map(\.continuation)
                    state.atLeastWaiters.removeAll { $0.count <= state.sleepers.count }
                    return ready
                }
                for waiter in ready { waiter.resume(returning: true) }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Waits until at least `count` tasks are asleep on this clock. Returns `false` when the clock was finished
    /// instead.
    func waitForSleepers(atLeast count: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let answer = state.withLock { state -> Bool? in
                if state.finished { return false }
                if state.sleepers.count >= count { return true }
                state.atLeastWaiters.append((count, continuation))
                return nil
            }
            if let answer { continuation.resume(returning: answer) }
        }
    }

    /// Ends every wait: later and pending `waitForSleepers` answer `false`.
    func finish() {
        let waiting = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
            state.finished = true
            defer { state.atLeastWaiters = [] }
            return state.atLeastWaiters.map(\.continuation)
        }
        for waiter in waiting { waiter.resume(returning: false) }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    func advance(_ duration: Duration) {
        let due = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.now = state.now.advanced(by: duration)
            let ready = state.sleepers.filter { $0.value.deadline <= state.now }
            for key in ready.keys { state.sleepers[key] = nil }
            return ready.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }
}

/// Reports through `done` once its base source has answered or thrown.
nonisolated struct SignallingSource: SearchSource {
    let base: any SearchSource
    let done: Gate

    var id: SourceID { base.id }

    func search(_ query: NormalizedQuery, limit: Int) async throws -> [Candidate] {
        defer { done.open() }
        return try await base.search(query, limit: limit)
    }
}

/// An `activate()` that does not return until the test opens the gate (a start stuck behind something it waits for).
final class StuckActivationPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "stuckactivation", displayName: "Stuck", symbolName: "tortoise", order: 8)

    private let gate: Gate

    init(context: PluginContext) {
        gate = context.services.value(StuckActivationGateKey.self, for: context)
    }

    func activate() async throws {
        await gate.wait()
    }
}

nonisolated enum StuckGateKey: PluginServiceKey {
    static func make(context: PluginContext) -> Gate { Gate() }
}

nonisolated enum StuckActivationGateKey: PluginServiceKey {
    static func make(context: PluginContext) -> Gate { Gate() }
}

nonisolated enum RecoveryScriptKey: PluginServiceKey {
    static func make(context: PluginContext) -> RecoveryScript { RecoveryScript() }
}

nonisolated enum OverrunControlKey: PluginServiceKey {
    static func make(context: PluginContext) -> OverrunControl { OverrunControl() }
}
