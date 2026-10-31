import AppKit
import Foundation
import PounceKit
import Synchronization
import os

@testable import AppsPlugin

/// In-memory ports so plugin tests never touch the real defaults, Keychain, pasteboard or workspace.
final class MemorySettings: SettingsStore {
    private let values = Mutex<[String: SettingValue]>([:])

    func value(forKey key: String) -> SettingValue? { values.withLock { $0[key] } }
    func setValue(_ value: SettingValue?, forKey key: String) { values.withLock { $0[key] = value } }
}

struct NoKeychain: KeychainClient {
    func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data {
        throw .itemNotFound
    }
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

struct NoPermissions: PermissionsReader {
    @MainActor func status(of permission: Permission) -> PermissionStatus { .notDetermined }
}

/// Records what the plugin asks the workspace to do.
@MainActor
final class RecordingWorkspace: WorkspaceClient {
    enum Call: Equatable {
        case open(URL)
        case openApplication(URL, ApplicationOpenOptions)
        case reveal([URL])
    }

    private(set) var calls: [Call] = []
    var failure: (any Error)?

    nonisolated var frontmostApplicationPID: pid_t? { nil }

    func open(_ url: URL) async throws { calls.append(.open(url)) }

    func revealInFinder(_ urls: [URL]) { calls.append(.reveal(urls)) }

    func openApplication(at url: URL, options: ApplicationOpenOptions) async throws {
        if let failure { throw failure }
        calls.append(.openApplication(url, options))
    }
}

/// Records uses and answers `mostUsed` from them.
actor RecordingUsage: UsageRecorder {
    private(set) var uses: [(ItemKey, String?)] = []

    func recordUse(of key: ItemKey, queryPrefix: String?, at date: Date) async throws {
        uses.append((key, queryPrefix))
    }

    func stats(for keys: [ItemKey], queryPrefix: String?) async throws -> [ItemKey: UsageStats] { [:] }

    func mostUsed(pluginID: PluginID, limit: Int, now: Date) async throws -> [ItemKey] {
        var counts: [ItemKey: Int] = [:]
        for (key, _) in uses where key.pluginID == pluginID {
            counts[key, default: 0] += 1
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
            .prefix(limit)
            .map(\.key)
    }
}

@MainActor
final class NoPanel: PanelPresenter {
    func hidePanel() {}
    func showConfirmation(_ message: LocalizedStringResource) {}
}

/// A temporary directory with fake `.app` bundles. Removed by `remove()`.
struct AppFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "pounce-apps-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Creates `<relativePath>` (ending in `.app`) with an Info.plist.
    @discardableResult
    func makeApp(
        _ relativePath: String,
        identifier: String?,
        name: String? = nil,
        displayName: String? = nil,
        extra: [String: Any] = [:]
    ) throws -> URL {
        let bundle = root.appending(path: relativePath, directoryHint: .isDirectory)
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = extra
        info["CFBundleIdentifier"] = identifier
        info["CFBundleName"] = name
        info["CFBundleDisplayName"] = displayName
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        return bundle
    }

    func url(_ relativePath: String) -> URL {
        root.appending(path: relativePath, directoryHint: .isDirectory)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// The file-name display name, so tests do not depend on LaunchServices or the system language.
let fileNameDisplayName: @Sendable (URL) -> String? = { $0.deletingPathExtension().lastPathComponent }

@MainActor
func makeContext(
    storage: URL,
    settings: MemorySettings,
    usage: any UsageRecorder,
    workspace: any WorkspaceClient,
    resultsChanged: @escaping @Sendable () -> Void = {}
) -> PluginContext {
    PluginContext(
        storageDirectory: storage,
        settings: PluginSettings(pluginID: "apps", store: settings),
        usage: usage,
        logger: Logger(subsystem: "app.pounce.tests", category: "apps"),
        keychain: NoKeychain(),
        pasteboard: NoPasteboard(),
        events: NoEvents(),
        workspace: workspace,
        permissions: NoPermissions(),
        clock: ContinuousClock(),
        resultsChanged: resultsChanged
    )
}
