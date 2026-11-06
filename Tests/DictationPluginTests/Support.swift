import Foundation
import LintelKit
import Synchronization
import os

/// Settings in memory (no `UserDefaults` suite left behind).
final class MemorySettingsStore: SettingsStore {
    private let values = Mutex<[String: SettingValue]>([:])

    init(_ initial: [String: SettingValue] = [:]) {
        values.withLock { $0 = initial }
    }

    func value(forKey key: String) -> SettingValue? { values.withLock { $0[key] } }

    func setValue(_ value: SettingValue?, forKey key: String) {
        values.withLock { $0[key] = value }
    }
}

/// A temporary directory removed when the test object is released.
final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "lintel-dictation-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

struct NoKeychain: KeychainClient {
    func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data {
        throw .itemNotFound
    }
    func addGenericPassword(_ data: Data, service: String, account: String) throws(KeychainError) {}
    func deleteGenericPassword(service: String, account: String) throws(KeychainError) {}
}

/// Records Command-V requests instead of posting them; never posts a real event.
@MainActor final class FakeEvents: EventPoster {
    var error: EventPosterError?
    private(set) var posts = 0

    nonisolated init() {}

    func postPaste() throws(EventPosterError) {
        if let error { throw error }
        posts += 1
    }
}

@MainActor final class FakePermissions: PermissionsReader {
    var states: [Permission: PermissionStatus] = [:]

    nonisolated init() {}

    func status(of permission: Permission) -> PermissionStatus {
        states[permission] ?? .granted
    }
}

/// Fails the test if dictation ever reaches `ranking.sqlite`.
final class NoUsage: UsageRecorder {
    let calls = Mutex(0)

    func recordUse(of key: ItemKey, queryPrefix: String?, at date: Date) async throws {
        calls.withLock { $0 += 1 }
    }

    func stats(for keys: [ItemKey], queryPrefix: String?) async throws -> [ItemKey: UsageStats] {
        calls.withLock { $0 += 1 }
        return [:]
    }

    func mostUsed(pluginID: PluginID, limit: Int, now: Date) async throws -> [ItemKey] {
        calls.withLock { $0 += 1 }
        return []
    }

    var callCount: Int { calls.withLock { $0 } }
}

/// Counts `PluginContext.resultsChanged` signals.
final class ChangeCounter: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    func bump() { count.withLock { $0 += 1 } }
}

/// A plugin context wired to fakes: a named pasteboard, in-memory settings, a temporary folder.
@MainActor
struct DictationHarness {
    let directory: TemporaryDirectory
    let settings: MemorySettingsStore
    let pasteboard = NamedPasteboard()
    let workspace = FakeWorkspace()
    let events = FakeEvents()
    let permissions = FakePermissions()
    let usage = NoUsage()
    /// How many times the plugin signalled `resultsChanged`.
    let changes = ChangeCounter()
    let context: PluginContext

    init(settings initial: [String: SettingValue] = [:], keychain: any KeychainClient = NoKeychain()) throws {
        let directory = try TemporaryDirectory()
        let settings = MemorySettingsStore(initial)
        let pasteboard = pasteboard
        let workspace = workspace
        let events = events
        let permissions = permissions
        let usage = usage
        let changes = changes
        self.directory = directory
        self.settings = settings
        context = PluginContext(
            storageDirectory: directory.url.appending(path: "Plugins/dictation", directoryHint: .isDirectory),
            settings: PluginSettings(pluginID: "dictation", store: settings),
            usage: usage,
            logger: Logger(subsystem: "com.lintelapp.tests", category: "dictation"),
            keychain: keychain,
            pasteboard: pasteboard,
            events: events,
            workspace: workspace,
            permissions: permissions,
            clock: ContinuousClock(),
            resultsChanged: { changes.bump() },
            modelsDirectory: directory.url.appending(path: "Models", directoryHint: .isDirectory)
        )
    }

    func tearDown() {
        pasteboard.release()
    }
}

/// A Keychain in memory whose reads can be made to fail.
final class MemoryKeychain: KeychainClient {
    struct State {
        var items: [String: Data] = [:]
        var readError: KeychainError?
    }

    let state = Mutex(State())

    var itemNames: Set<String> { state.withLock { Set($0.items.keys) } }

    func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data {
        let result: Result<Data, KeychainError> = state.withLock { state in
            if let error = state.readError { return .failure(error) }
            guard let data = state.items["\(service)/\(account)"] else { return .failure(.itemNotFound) }
            return .success(data)
        }
        return try result.get()
    }

    func addGenericPassword(_ data: Data, service: String, account: String) throws(KeychainError) {
        state.withLock { $0.items["\(service)/\(account)"] = data }
    }

    func deleteGenericPassword(service: String, account: String) throws(KeychainError) {
        let found = state.withLock { $0.items.removeValue(forKey: "\(service)/\(account)") != nil }
        if !found { throw .itemNotFound }
    }
}
