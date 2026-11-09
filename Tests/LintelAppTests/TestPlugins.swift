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

/// Never answers and ignores cancellation, like a source stuck in blocking work.
struct StuckSource: SearchSource {
    let id: SourceID = "stuck"

    func search(_ query: NormalizedQuery, limit: Int) async throws -> [Candidate] {
        // Blocks a background thread far beyond any budget without checking cancellation.
        await Task.detached {
            blockCurrentThread(microseconds: 5_000_000)
        }.value
        return []
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

    init(context: PluginContext) {}

    var searchSources: [any SearchSource] { [StuckSource(), ThrowingSource()] }
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
        recoveryBudget: Duration = .seconds(5)
    ) -> PluginHost {
        PluginHost(
            pluginTypes: types,
            makeContext: { environment.makeContext(for: $0) },
            settings: settings,
            sourceBudget: budget,
            recoveryBudget: recoveryBudget
        )
    }

    func tearDown() {
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

/// Records `recoverAtLaunch` calls and answers with a scripted outcome, enabled or not.
final class LaunchRecoveryPlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "launchrecovery", displayName: "Launch recovery", symbolName: "arrow.uturn.backward", order: 6,
        defaultEnabled: false)

    init(context: PluginContext) {}

    nonisolated static func recoverAtLaunch(context: PluginContext) async -> RecoveryOutcome {
        RecoveryScript.shared.next()
    }
}

/// The scripted answers of `LaunchRecoveryPlugin`; the last one repeats. Thread-safe because the host calls
/// `recoverAtLaunch` off the main actor.
nonisolated final class RecoveryScript: @unchecked Sendable {
    static let shared = RecoveryScript()
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

/// A `recoverAtLaunch` that ignores its bound and cancellation until the test releases it, and counts how often it
/// was entered. Nothing here depends on how long the test takes, so a busy machine cannot finish it early.
final class OverrunRecoveryPlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "overrunrecovery", displayName: "Overrun recovery", symbolName: "tortoise", order: 7,
        defaultEnabled: false)

    init(context: PluginContext) {}

    nonisolated static let entered = Mutex(0)

    private struct Gate {
        var released = false
        var waiting: CheckedContinuation<Void, Never>?
    }

    private nonisolated static let gate = Mutex(Gate())

    nonisolated static func reset() {
        entered.withLock { $0 = 0 }
        gate.withLock { $0 = Gate() }
    }

    /// Lets every pending and later call return.
    nonisolated static func release() {
        let waiting = gate.withLock { gate -> CheckedContinuation<Void, Never>? in
            gate.released = true
            defer { gate.waiting = nil }
            return gate.waiting
        }
        waiting?.resume()
    }

    nonisolated static func recoverAtLaunch(context: PluginContext) async -> RecoveryOutcome {
        entered.withLock { $0 += 1 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed = gate.withLock { gate -> Bool in
                if gate.released { return true }
                gate.waiting = continuation
                return false
            }
            if proceed { continuation.resume() }
        }
        return .done
    }
}
