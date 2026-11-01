import Foundation
import PounceCore
import PounceKit
import Synchronization
import Testing
import os

@testable import FilesPlugin

/// A temporary directory removed when the test ends. Paths are resolved (`/private/var/…`) so they match
/// what the scanner and FSEvents report.
final class TemporaryDirectory: Sendable {
    let url: URL
    var path: String { url.path }

    init() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        url = base.appending(path: "pounce-files-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Creates the files and folders (a trailing `/` makes a folder) below the directory.
    @discardableResult
    func make(_ items: [String]) throws -> TemporaryDirectory {
        for item in items {
            let target = url.appending(path: item)
            if item.hasSuffix("/") {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: target)
            }
        }
        return self
    }

    func sub(_ relative: String) -> String {
        url.appending(path: relative).path
    }
}

/// Settings in memory (no `UserDefaults` suite left behind).
final class MemorySettings: SettingsStore {
    private let values = Mutex<[String: SettingValue]>([:])

    init(_ initial: [String: SettingValue] = [:]) {
        values.withLock { $0 = initial }
    }

    func value(forKey key: String) -> SettingValue? { values.withLock { $0[key] } }
    func setValue(_ value: SettingValue?, forKey key: String) { values.withLock { $0[key] = value } }
}

/// Collects scanner listings into relative paths.
final class ListingCollector: Sendable {
    private let state = Mutex<(paths: [Int32: String], found: [String: EntryKind], outOfOrder: Bool)>(
        ([0: ""], [:], false))

    func add(_ listings: [ScannedDirectory]) {
        state.withLock { state in
            for listing in listings {
                guard let base = state.paths[listing.id] else {
                    state.outOfOrder = true
                    continue
                }
                for entry in listing.entries {
                    let path = base.isEmpty ? entry.name : base + "/" + entry.name
                    state.found[path] = entry.kind
                    if let id = entry.directoryID {
                        state.paths[id] = path
                    }
                }
            }
        }
    }

    var found: [String: EntryKind] { state.withLock { $0.found } }
    /// Whether every listing arrived after the listing that announced it.
    var parentsFirst: Bool { state.withLock { !$0.outOfOrder } }
}

/// A pasteboard in memory: never the tester's clipboard.
@MainActor final class MemoryPasteboard: PasteboardClient {
    private(set) var items: [PasteboardItem] = []
    private(set) var count = 0

    nonisolated init() {}

    var changeCount: Int { count }
    func string() -> String? {
        items.first?.data(for: PasteboardRepresentation.plainTextType).map { String(decoding: $0, as: UTF8.self) }
    }
    func setString(_ string: String) -> Int {
        write([
            PasteboardItem(representations: [
                PasteboardRepresentation(type: PasteboardRepresentation.plainTextType, data: Data(string.utf8))
            ])
        ])
    }
    func write(_ items: [PasteboardItem]) -> Int {
        self.items = items
        count += 1
        return count
    }
}

/// Records what the plugin asks the workspace to do.
@MainActor final class RecordingWorkspace: WorkspaceClient {
    private(set) var opened: [URL] = []
    private(set) var revealed: [[URL]] = []

    nonisolated init() {}

    var frontmostApplicationPID: pid_t? { nil }
    func open(_ url: URL) async throws { opened.append(url) }
    func revealInFinder(_ urls: [URL]) { revealed.append(urls) }
}

@MainActor final class FakePermissions: PermissionsReader {
    var fullDiskAccess: PermissionStatus = .denied
    nonisolated init() {}
    func status(of permission: Permission) -> PermissionStatus {
        permission == .fullDiskAccess ? fullDiskAccess : .granted
    }
}

struct NoKeychain: KeychainClient {
    func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data { throw .itemNotFound }
    func addGenericPassword(_ data: Data, service: String, account: String) throws(KeychainError) {}
    func deleteGenericPassword(service: String, account: String) throws(KeychainError) {}
}

struct NoEvents: EventPoster {
    @MainActor func postPaste() throws(EventPosterError) { throw .notPermitted }
}

@MainActor final class FakePanel: PanelPresenter {
    private(set) var confirmations: [String] = []
    nonisolated init() {}
    func hidePanel() {}
    func showConfirmation(_ message: LocalizedStringResource) { confirmations.append(message.key) }
}

/// Records uses and answers `mostUsed` from them.
actor RecordingUsage: UsageRecorder {
    private(set) var uses: [(ItemKey, String?)] = []
    private(set) var removed: [PluginID] = []

    func recordUse(of key: ItemKey, queryPrefix: String?, at date: Date) async throws {
        uses.append((key, queryPrefix))
    }

    func stats(for keys: [ItemKey], queryPrefix: String?) async throws -> [ItemKey: UsageStats] { [:] }

    func mostUsed(pluginID: PluginID, limit: Int, now: Date) async throws -> [ItemKey] {
        var seen: [ItemKey] = []
        for (key, _) in uses.reversed() where key.pluginID == pluginID && !seen.contains(key) {
            seen.append(key)
        }
        return Array(seen.prefix(limit))
    }

    func removeAll(pluginID: PluginID) async throws { removed.append(pluginID) }
}

/// Counts `resultsChanged` calls from any thread.
final class ChangeCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func signal() { count.withLock { $0 += 1 } }
}

/// A plugin wired to fakes: settings in memory, a fake home and fixture roots in a temporary folder.
@MainActor
struct PluginHarness {
    let directory: TemporaryDirectory
    let settings: MemorySettings
    let permissions = FakePermissions()
    let workspace = RecordingWorkspace()
    let pasteboard = MemoryPasteboard()
    let usage = RecordingUsage()
    let changes = ChangeCounter()
    let plugin: FilesPlugin

    var storage: URL { directory.url.appending(path: "Plugins/files", directoryHint: .isDirectory) }
    var home: String { directory.sub("home") }

    /// - Parameter settings: extra settings; the roots default to the fake home.
    init(directory: TemporaryDirectory? = nil, settings extra: [String: SettingValue] = [:]) throws {
        let directory = try directory ?? TemporaryDirectory()
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory.url.appending(path: "Plugins/files"), withIntermediateDirectories: true)
        var initial: [String: SettingValue] = [
            "plugins.files.qaHome": .string(directory.sub("home")),
            "plugins.files.roots": .stringArray([directory.sub("home")]),
        ]
        initial.merge(extra) { _, new in new }
        settings = MemorySettings(initial)
        let changes = changes
        let context = PluginContext(
            storageDirectory: directory.url.appending(path: "Plugins/files", directoryHint: .isDirectory),
            settings: PluginSettings(pluginID: "files", store: settings),
            usage: usage,
            logger: Logger(subsystem: "app.pounce.tests", category: "files"),
            keychain: NoKeychain(),
            pasteboard: pasteboard,
            events: NoEvents(),
            workspace: workspace,
            permissions: permissions,
            clock: ContinuousClock(),
            resultsChanged: { changes.signal() }
        )
        plugin = FilesPlugin(context: context)
    }

    func names(_ text: String, limit: Int = 50) async throws -> [String] {
        let source = try #require(plugin.searchSources.first)
        return try await source.search(TextNormalizer.query(text), limit: limit).map(\.title)
    }
}

/// Polls until `condition` holds.
@MainActor func eventually(timeout: Duration = .seconds(5), _ condition: () async throws -> Bool) async rethrows -> Bool
{
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return try await condition()
}
