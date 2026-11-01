import Foundation
import PounceKit
import Synchronization
import os

@testable import ClipboardPlugin

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
    var accessibility: PermissionStatus = .granted

    nonisolated init() {}

    func status(of permission: Permission) -> PermissionStatus {
        permission == .accessibility ? accessibility : .granted
    }
}

@MainActor final class FakePanel: PanelPresenter {
    private(set) var confirmations: [String] = []
    private(set) var hidden = 0

    nonisolated init() {}

    func hidePanel() { hidden += 1 }

    func showConfirmation(_ message: LocalizedStringResource) {
        confirmations.append(message.key)
    }
}

/// Counts `resultsChanged` calls from any thread.
final class ChangeCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func signal() { count.withLock { $0 += 1 } }
}

/// A plugin wired to fakes: a named pasteboard, an in-memory keychain and settings, a temporary folder.
@MainActor
struct PluginHarness {
    let directory: TemporaryDirectory
    let keychain = FakeKeychain()
    let settings: MemorySettingsStore
    let pasteboard = NamedPasteboard()
    let workspace = FakeWorkspace()
    let events = FakeEvents()
    let permissions = FakePermissions()
    let changes = ChangeCounter()
    let usage = NoUsage()
    let plugin: ClipboardPlugin

    init(settings initial: [String: SettingValue] = [:]) throws {
        directory = try TemporaryDirectory()
        settings = MemorySettingsStore(initial)
        let changes = changes
        let context = PluginContext(
            storageDirectory: directory.url.appending(path: "Plugins/clipboard", directoryHint: .isDirectory),
            settings: PluginSettings(pluginID: "clipboard", store: settings),
            usage: usage,
            logger: Logger(subsystem: "app.pounce.tests", category: "clipboard"),
            keychain: keychain,
            pasteboard: pasteboard,
            events: events,
            workspace: workspace,
            permissions: permissions,
            clock: ContinuousClock(),
            resultsChanged: { changes.signal() }
        )
        plugin = ClipboardPlugin(context: context)
    }

    func tearDown() async {
        await plugin.deactivate()
        pasteboard.release()
    }

    func actionContext(_ panel: FakePanel, previousApp: pid_t? = 501) -> ActionContext {
        ActionContext(previousApp: previousApp, panel: panel)
    }
}

/// Fails the test if the clipboard ever reaches `ranking.sqlite`.
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

/// Polls until `condition` holds (background stores finish asynchronously).
@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
