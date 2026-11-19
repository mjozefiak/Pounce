import Foundation
import LintelCore
import LintelKit
import Observation
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
        url = base.appending(path: "lintel-files-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
    /// Signals after every `open`.
    let openings = ChangeCounter()

    nonisolated init() {}

    var frontmostApplicationPID: pid_t? { nil }
    func open(_ url: URL) async throws {
        opened.append(url)
        openings.signal()
    }
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

/// Counts events from any thread (`resultsChanged`, `onChange`, `onStatus`) and lets a test wait for the next
/// one. A waiter ends when the count passes the value it saw, when its task is cancelled, or, as a hang
/// guard only, after `limit`.
final class ChangeCounter: Sendable {
    private struct State {
        var count = 0
        var nextID = 0
        var waiters: [Int: (after: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]
        var cancelled: Set<Int> = []
    }
    private let state = Mutex(State())
    var value: Int { state.withLock { $0.count } }

    func signal() {
        let ready = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
            state.count += 1
            let passed = state.waiters.filter { $0.value.after < state.count }
            for id in passed.keys { state.waiters[id] = nil }
            return passed.values.map(\.continuation)
        }
        for continuation in ready { continuation.resume(returning: true) }
    }

    /// `true` once the count is above `seen`; `false` when the task was cancelled or `limit` passed.
    func wait(after seen: Int, limit: Duration = .seconds(60)) async -> Bool {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        let guardTask = Task { [self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            release(id, returning: false)
        }
        defer { guardTask.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                enum Outcome {
                    case wait
                    case now(Bool)
                }
                let outcome = state.withLock { state -> Outcome in
                    if state.cancelled.remove(id) != nil { return .now(false) }
                    if state.count > seen { return .now(true) }
                    state.waiters[id] = (seen, continuation)
                    return .wait
                }
                if case .now(let result) = outcome { continuation.resume(returning: result) }
            }
        } onCancel: {
            release(id, returning: false)
        }
    }

    private func release(_ id: Int, returning result: Bool) {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            if let waiter = state.waiters.removeValue(forKey: id) { return waiter.continuation }
            state.cancelled.insert(id)
            return nil
        }
        continuation?.resume(returning: result)
    }
}

/// Waits until `condition` holds, checking again after every event of `counter`. Not a poll: the next check
/// happens when something changed. The 60 s limit only ends a hang, and reports it at the caller's line.
@MainActor
func awaitEvents(
    _ counter: ChangeCounter, limit: Duration = .seconds(60), sourceLocation: SourceLocation = #_sourceLocation,
    until condition: () async throws -> Bool
) async rethrows -> Bool {
    while true {
        let seen = counter.value
        if try await condition() { return true }
        guard await counter.wait(after: seen, limit: limit) else {
            if !Task.isCancelled {
                Issue.record(
                    "Nothing changed for \(limit) while waiting for a condition", sourceLocation: sourceLocation)
            }
            return false
        }
    }
}

/// Waits until `condition`, which reads observable state, holds; it is evaluated again whenever a value it
/// read changes. The 60 s limit only ends a hang, and reports it at the caller's line.
@MainActor
func awaitState(
    limit: Duration = .seconds(60), sourceLocation: SourceLocation = #_sourceLocation,
    until condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while true {
        let changed = ChangeCounter()
        if withObservationTracking({ condition() }, onChange: { changed.signal() }) { return true }
        guard await changed.wait(after: 0, limit: max(.zero, clock.now.duration(to: deadline))) else {
            if !Task.isCancelled {
                Issue.record(
                    "State did not change within \(limit) while waiting for a condition", sourceLocation: sourceLocation
                )
            }
            return false
        }
    }
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
            logger: Logger(subsystem: "com.lintelapp.tests", category: "files"),
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
