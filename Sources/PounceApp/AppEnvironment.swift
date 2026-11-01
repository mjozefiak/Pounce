import AppKit
import Foundation
import PounceKit
import os

/// Where the app keeps its data and which port implementations plugins get. `live()` is the normal
/// app; QA mode (DEBUG builds only) swaps every piece that could touch the user's real data.
struct AppEnvironment {
    /// `~/Library/Application Support/Pounce` (0700), or a temporary root in QA mode.
    let dataRoot: URL
    /// Settings (`app.*`, `plugins.<id>.*`): `UserDefaults.standard` normally, in memory in QA mode.
    let settings: any SettingsStore
    let keychain: any KeychainClient
    let pasteboardName: NSPasteboard.Name?
    let usage: any UsageRecorder
    /// False in QA mode, so a QA run never takes the user's global shortcuts.
    let registersGlobalHotkeys: Bool

    /// `Plugins/<id>/` under the data root.
    func storageDirectory(for id: PluginID) -> URL {
        dataRoot
            .appending(path: "Plugins", directoryHint: .isDirectory)
            .appending(path: id.rawValue, directoryHint: .isDirectory)
    }

    func makeContext(for manifest: PluginManifest) -> PluginContext {
        PluginContext(
            storageDirectory: storageDirectory(for: manifest.id),
            settings: PluginSettings(pluginID: manifest.id, store: settings),
            usage: usage,
            logger: Logger(subsystem: "app.pounce", category: manifest.id.rawValue),
            keychain: keychain,
            pasteboard: SystemPasteboardClient(name: pasteboardName),
            events: SystemEventPoster(),
            workspace: SystemWorkspaceClient(),
            permissions: SystemPermissionsReader(pasteboardName: pasteboardName),
            clock: ContinuousClock()
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
        return AppEnvironment(
            dataRoot: root,
            settings: UserDefaultsSettingsStore(),
            keychain: SystemKeychainClient(),
            pasteboardName: nil,
            usage: InMemoryUsageRecorder(),
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
        return AppEnvironment(
            dataRoot: root,
            settings: InMemorySettingsStore(),
            keychain: InMemoryKeychainClient(),
            pasteboardName: NSPasteboard.Name("app.pounce.qa.\(ProcessInfo.processInfo.processIdentifier)"),
            usage: InMemoryUsageRecorder(),
            registersGlobalHotkeys: false
        )
    }
    #endif

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
