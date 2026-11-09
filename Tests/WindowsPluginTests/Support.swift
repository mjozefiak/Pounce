import Foundation
import LintelKit
import os

@testable import WindowsPlugin

/// In-memory ports and a temporary directory for one test; `tearDown()` removes what it made.
final class WindowsHarness: @unchecked Sendable {
    let directory: URL
    let store = MemorySettings()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "lintel-windows-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var pluginSettings: PluginSettings { PluginSettings(pluginID: "windows", store: store) }

    func context(windows: any WindowClient = NoWindowClient()) -> PluginContext {
        PluginContext(
            storageDirectory: directory,
            settings: pluginSettings,
            usage: NoUsage(),
            logger: Logger(subsystem: "com.lintelapp.tests", category: "windows"),
            keychain: NoKeychain(),
            pasteboard: NoPasteboard(),
            events: NoEvents(),
            workspace: NoWorkspace(),
            permissions: NoPermissions(),
            clock: ContinuousClock(),
            windows: windows
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }
}

final class MemorySettings: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: SettingValue] = [:]

    func value(forKey key: String) -> SettingValue? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func setValue(_ value: SettingValue?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    var keys: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(values.keys)
    }
}

struct NoKeychain: KeychainClient {
    func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data { throw .itemNotFound }
    func addGenericPassword(_ data: Data, service: String, account: String) throws(KeychainError) {}
    func deleteGenericPassword(service: String, account: String) throws(KeychainError) {}
}

struct NoPasteboard: PasteboardClient {
    @MainActor var changeCount: Int { 0 }
    @MainActor func string() -> String? { nil }
    @MainActor func setString(_ string: String) -> Int { 0 }
}

struct NoEvents: EventPoster {
    @MainActor func postPaste() throws(EventPosterError) { throw .notPermitted }
}

struct NoWorkspace: WorkspaceClient {
    @MainActor var frontmostApplicationPID: pid_t? { nil }
    @MainActor func open(_ url: URL) async throws {}
    @MainActor func revealInFinder(_ urls: [URL]) {}
}

struct NoUsage: UsageRecorder {
    func recordUse(of key: ItemKey, queryPrefix: String?, at date: Date) async throws {}
    func stats(for keys: [ItemKey], queryPrefix: String?) async throws -> [ItemKey: UsageStats] { [:] }
}

struct NoPermissions: PermissionsReader {
    @MainActor func status(of permission: Permission) -> PermissionStatus { .notDetermined }
}
