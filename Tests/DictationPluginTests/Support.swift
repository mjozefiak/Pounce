import Foundation
import PounceKit
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
            .appending(path: "pounce-dictation-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
    let context: PluginContext

    init(settings initial: [String: SettingValue] = [:]) throws {
        let directory = try TemporaryDirectory()
        let settings = MemorySettingsStore(initial)
        let pasteboard = pasteboard
        let workspace = workspace
        let events = events
        let permissions = permissions
        let usage = usage
        self.directory = directory
        self.settings = settings
        context = PluginContext(
            storageDirectory: directory.url.appending(path: "Plugins/dictation", directoryHint: .isDirectory),
            settings: PluginSettings(pluginID: "dictation", store: settings),
            usage: usage,
            logger: Logger(subsystem: "app.pounce.tests", category: "dictation"),
            keychain: NoKeychain(),
            pasteboard: pasteboard,
            events: events,
            workspace: workspace,
            permissions: permissions,
            clock: ContinuousClock()
        )
    }

    func tearDown() {
        pasteboard.release()
    }
}
