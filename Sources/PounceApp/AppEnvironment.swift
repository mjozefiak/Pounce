import AppKit
import Foundation
import PounceCore
import PounceKit
import PouncePersistence
import SwiftUI
import os

/// Where the app keeps its data and which port implementations plugins get. `live()` is the normal
/// app; QA mode (DEBUG builds only) swaps every piece that could touch the user's real data.
struct AppEnvironment {
    /// `~/Library/Application Support/Pounce` (0700), or a temporary root in QA mode.
    let dataRoot: URL
    /// `~/Library/Caches/Pounce`, or `Caches/` under the data root in QA mode. Rebuildable.
    let cachesRoot: URL
    /// Settings (`app.*`, `plugins.<id>.*`): `UserDefaults.standard` normally, in memory in QA mode.
    let settings: any SettingsStore
    let keychain: any KeychainClient
    let pasteboardName: NSPasteboard.Name?
    let usage: any UsageRecorder
    /// False in QA mode, so a QA run never takes the user's global shortcuts.
    let registersGlobalHotkeys: Bool
    /// QA mode only: the pasteboard access behaviour plugins see (`--qa-pasteboard-access`).
    var pasteboardAccess: PasteboardAccess?
    /// QA mode only: the Accessibility status plugins see (`--qa-accessibility`), instead of the system's.
    var accessibility: PermissionStatus?

    /// `Plugins/<id>/` under the data root.
    func storageDirectory(for id: PluginID) -> URL {
        dataRoot
            .appending(path: "Plugins", directoryHint: .isDirectory)
            .appending(path: id.rawValue, directoryHint: .isDirectory)
    }

    /// `Plugins/<id>/` under the caches root.
    func cachesDirectory(for id: PluginID) -> URL {
        cachesRoot
            .appending(path: "Plugins", directoryHint: .isDirectory)
            .appending(path: id.rawValue, directoryHint: .isDirectory)
    }

    /// - Parameters:
    ///   - resultsChanged: called by the plugin when its results change (see `PluginContext`).
    ///   - makeShortcutRecorder: the shell's recorder for one of the plugin's commands.
    func makeContext(
        for manifest: PluginManifest,
        resultsChanged: @escaping @Sendable () -> Void = {},
        makeShortcutRecorder: @escaping @MainActor @Sendable (String) -> AnyView = { _ in AnyView(EmptyView()) }
    ) -> PluginContext {
        PluginContext(
            storageDirectory: storageDirectory(for: manifest.id),
            settings: PluginSettings(pluginID: manifest.id, store: settings),
            usage: usage,
            logger: Logger(subsystem: "app.pounce", category: manifest.id.rawValue),
            keychain: keychain,
            pasteboard: SystemPasteboardClient(name: pasteboardName, accessOverride: pasteboardAccess),
            events: SystemEventPoster(),
            workspace: SystemWorkspaceClient(),
            permissions: SystemPermissionsReader(
                pasteboardName: pasteboardName, accessibilityOverride: accessibility),
            clock: ContinuousClock(),
            cachesDirectory: cachesDirectory(for: manifest.id),
            resultsChanged: resultsChanged,
            makeShortcutRecorder: makeShortcutRecorder
        )
    }

    static func live(fileManager: FileManager = .default) throws -> AppEnvironment {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appending(path: "Pounce", directoryHint: .isDirectory)
        try createPrivateDirectory(root, fileManager: fileManager)
        let caches = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return AppEnvironment(
            dataRoot: root,
            cachesRoot: caches.appending(path: "Pounce", directoryHint: .isDirectory),
            settings: UserDefaultsSettingsStore(),
            keychain: SystemKeychainClient(),
            pasteboardName: nil,
            usage: openRanking(in: root),
            registersGlobalHotkeys: true
        )
    }

    #if DEBUG
    static func qa(_ options: QAOptions, fileManager: FileManager = .default) throws -> AppEnvironment {
        let root =
            options.dataRoot
            ?? fileManager.temporaryDirectory.appending(
                path: "pounce-qa-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try createPrivateDirectory(root, fileManager: fileManager)
        let settings = InMemorySettingsStore(options.settings)
        return AppEnvironment(
            dataRoot: root,
            cachesRoot: root.appending(path: "Caches", directoryHint: .isDirectory),
            settings: settings,
            keychain: InMemoryKeychainClient(),
            pasteboardName: NSPasteboard.Name("app.pounce.qa.\(ProcessInfo.processInfo.processIdentifier)"),
            usage: openRanking(in: root),
            registersGlobalHotkeys: false,
            pasteboardAccess: options.pasteboardAccess,
            accessibility: options.accessibility
        )
    }
    #endif

    /// `ranking.sqlite` at the data root. If it cannot be opened, ranking falls back to memory for this
    /// session instead of stopping the app.
    static func openRanking(in root: URL) -> any UsageRecorder {
        do {
            return try UsageRepository.open(
                at: root.appending(path: UsageRepository.fileName),
                halfLife: Ranker.frecencyHalfLife
            )
        } catch {
            Logger(subsystem: "app.pounce", category: "app")
                .error("Cannot open ranking.sqlite: \(String(describing: error), privacy: .private)")
            return InMemoryUsageRecorder()
        }
    }

    /// Creates a directory with mode 0700 (and tightens an existing one).
    static func createPrivateDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
