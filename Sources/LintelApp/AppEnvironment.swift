import AppKit
import Foundation
import LintelCore
import LintelKit
import LintelPersistence
import SwiftUI
import os

/// Where the app keeps its data and which port implementations plugins get. `live()` is the normal
/// app; QA mode (DEBUG builds only) swaps every piece that could touch the user's real data.
struct AppEnvironment {
    /// `~/Library/Application Support/Lintel` (0700), or a temporary root in QA mode.
    let dataRoot: URL
    /// `~/Library/Caches/Lintel`, or `Caches/` under the data root in QA mode. Rebuildable.
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
    /// QA mode only: the Full Disk Access status plugins see (`--qa-full-disk-access`, default denied), so
    /// a QA run never probes a protected folder.
    var fullDiskAccess: PermissionStatus?
    /// False in QA mode: a paste is logged instead of posting a real Command-V to the tester's apps.
    var postsKeystrokes = true

    /// `Plugins/<id>/` under the data root.
    func storageDirectory(for id: PluginID) -> URL {
        dataRoot
            .appending(path: "Plugins", directoryHint: .isDirectory)
            .appending(path: id.rawValue, directoryHint: .isDirectory)
    }

    /// `Models/` under the data root: downloaded speech and language models shared by all plugins.
    var modelsDirectory: URL {
        dataRoot.appending(path: "Models", directoryHint: .isDirectory)
    }

    /// Creates `Models/` (0700) and moves the models of the previous layout into it. Runs at launch before any
    /// plugin activates, whether or not the plugin that owns the models is enabled.
    func prepareModelsDirectory(fileManager: FileManager = .default) {
        do {
            try Self.createPrivateDirectory(modelsDirectory, fileManager: fileManager)
        } catch {
            Logger(subsystem: "com.lintelapp", category: "app")
                .error("Cannot create Models: \(String(describing: error), privacy: .public)")
        }
        ModelsMigration(dataRoot: dataRoot, fileManager: fileManager).run()
    }

    /// `Plugins/<id>/` under the caches root.
    func cachesDirectory(for id: PluginID) -> URL {
        cachesRoot
            .appending(path: "Plugins", directoryHint: .isDirectory)
            .appending(path: id.rawValue, directoryHint: .isDirectory)
    }

    /// The permission states plugins and Settings → Permissions read (preflight only, never a prompt). In QA
    /// mode the overrides replace the system's answers.
    var permissionsReader: SystemPermissionsReader {
        SystemPermissionsReader(
            pasteboardName: pasteboardName,
            accessibilityOverride: accessibility,
            fullDiskAccessOverride: fullDiskAccess,
            pasteboardAccessOverride: pasteboardAccess
        )
    }

    /// - Parameters:
    ///   - resultsChanged: called by the plugin when its results change (see `PluginContext`).
    ///   - makeShortcutRecorder: the shell's recorder for one of the plugin's commands.
    ///   - claimEscapeKey: the shell's temporary Escape claim.
    ///   - openSettings: opens the plugin's own Settings pane.
    ///   - openModels: opens the Models pane, or the pane that shows the model (`MainWindowRouter`).
    ///   - noteSources: the active plugins' note sources (`NoteSourcesRelay`).
    ///   - noteSourcesChanged: yields when a plugin was switched on or off.
    ///   - openNote: asks the main window's sections to show a note.
    ///   - keptNoteCopies, deleteKeptNoteCopies: what Notes keeps of a plugin's recordings and its removal
    ///     (`NoteSourcesRelay`, answered by the plugin that implements `keptNoteCopyCount`).
    func makeContext(
        for manifest: PluginManifest,
        resultsChanged: @escaping @Sendable () -> Void = {},
        makeShortcutRecorder: @escaping @MainActor @Sendable (String) -> AnyView = { _ in AnyView(EmptyView()) },
        claimEscapeKey:
            @escaping @MainActor @Sendable (_ onEscape: @escaping @MainActor @Sendable () -> Void) ->
            EscapeKeyClaim = { _ in .inactive },
        openSettings: @escaping @MainActor @Sendable () -> Void = {},
        openModels: @escaping @MainActor @Sendable (String?) -> Void = { _ in },
        noteSources: @escaping @MainActor @Sendable () -> [any NoteSource] = { [] },
        noteSourcesChanged: @escaping @Sendable () -> AsyncStream<Void> = { AsyncStream { $0.finish() } },
        openNote: @escaping @MainActor @Sendable (NoteKey) -> Bool = { _ in false },
        keptNoteCopies: @escaping @MainActor @Sendable (PluginID) async -> Int = { _ in 0 },
        deleteKeptNoteCopies: @escaping @MainActor @Sendable (PluginID, Bool) async -> Bool = { _, _ in true }
    ) -> PluginContext {
        PluginContext(
            storageDirectory: storageDirectory(for: manifest.id),
            settings: PluginSettings(pluginID: manifest.id, store: settings),
            usage: usage,
            logger: Logger(subsystem: "com.lintelapp", category: manifest.id.rawValue),
            keychain: keychain,
            pasteboard: SystemPasteboardClient(name: pasteboardName, accessOverride: pasteboardAccess),
            events: postsKeystrokes ? SystemEventPoster() : LoggingEventPoster(),
            workspace: SystemWorkspaceClient(),
            permissions: permissionsReader,
            clock: ContinuousClock(),
            cachesDirectory: cachesDirectory(for: manifest.id),
            resultsChanged: resultsChanged,
            makeShortcutRecorder: makeShortcutRecorder,
            claimEscapeKey: claimEscapeKey,
            openSettings: openSettings,
            modelsDirectory: modelsDirectory,
            openModels: openModels,
            noteSources: noteSources,
            noteSourcesChanged: noteSourcesChanged,
            openNote: openNote,
            keptNoteCopies: keptNoteCopies,
            deleteKeptNoteCopies: deleteKeptNoteCopies
        )
    }

    static func live(fileManager: FileManager = .default) throws -> AppEnvironment {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let caches = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Before anything creates the new folders: moves what the app kept under its previous name. It runs
        // before `prepareModelsDirectory`, which then moves the dictation models inside the new folder.
        LegacyDataMigration(fileManager: fileManager).run(supportDirectory: support, cachesDirectory: caches)
        let root = support.appending(path: "Lintel", directoryHint: .isDirectory)
        try createPrivateDirectory(root, fileManager: fileManager)
        let environment = AppEnvironment(
            dataRoot: root,
            cachesRoot: caches.appending(path: "Lintel", directoryHint: .isDirectory),
            settings: UserDefaultsSettingsStore(),
            keychain: SystemKeychainClient(),
            pasteboardName: nil,
            usage: openRanking(in: root),
            registersGlobalHotkeys: true
        )
        environment.prepareModelsDirectory(fileManager: fileManager)
        return environment
    }

    #if DEBUG
    static func qa(_ options: QAOptions, fileManager: FileManager = .default) throws -> AppEnvironment {
        let root =
            options.dataRoot
            ?? fileManager.temporaryDirectory.appending(
                path: "lintel-qa-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try createPrivateDirectory(root, fileManager: fileManager)
        let fileHome = root.appending(path: "files-home", directoryHint: .isDirectory)
        try createPrivateDirectory(fileHome, fileManager: fileManager)
        let settings = InMemorySettingsStore(
            qaNotesSettings(
                qaAppActivitySettings(
                    qaFileIndexSettings(options.settings, emptyHome: fileHome.path),
                    activity: options.appActivity,
                    live: options.liveAppActivity
                ),
                fixtures: options.notesFixtures
            )
        )
        let environment = AppEnvironment(
            dataRoot: root,
            cachesRoot: root.appending(path: "Caches", directoryHint: .isDirectory),
            settings: settings,
            keychain: InMemoryKeychainClient(),
            pasteboardName: NSPasteboard.Name("com.lintelapp.qa.\(ProcessInfo.processInfo.processIdentifier)"),
            usage: openRanking(in: root),
            registersGlobalHotkeys: false,
            pasteboardAccess: options.pasteboardAccess,
            accessibility: options.accessibility,
            fullDiskAccess: options.fullDiskAccess ?? .denied,
            postsKeystrokes: false
        )
        environment.prepareModelsDirectory(fileManager: fileManager)
        return environment
    }

    /// The file index in QA mode never sees the tester's folders: unless the run names a fake home
    /// (`plugins.files.qaHome`) and roots (`plugins.files.roots`), both point at an empty folder in the QA
    /// data root, so neither the home folder nor `/Applications` is ever scanned (`docs/qa.md`).
    static func qaFileIndexSettings(_ settings: [String: SettingValue], emptyHome: String) -> [String: SettingValue] {
        var result = settings
        let home: SettingValue = settings[QAOptions.filesHomeKey] ?? .string(emptyHome)
        result[QAOptions.filesHomeKey] = home
        if settings[QAOptions.filesRootsKey] == nil {
            result[QAOptions.filesRootsKey] = home
        }
        return result
    }

    /// `--qa-notes` turns on `plugins.notes.qaFixtures`, so the Notes section lists its fixture notes.
    static func qaNotesSettings(_ settings: [String: SettingValue], fixtures: Bool) -> [String: SettingValue] {
        var result = settings
        if fixtures { result[QAOptions.notesFixturesKey] = .bool(true) }
        return result
    }

    /// App suggestions in QA mode never learn from the tester's real activity: unless the run passes
    /// `--qa-activity-live`, `plugins.apps.qaLiveActivity` is `false`, so the tracker and the Spotlight
    /// seed do not start. `--qa-activity` entries become `plugins.apps.qaActivity`, which the plugin writes
    /// into its empty QA store (`docs/qa.md`). The shell never reads `activity.json` itself.
    static func qaAppActivitySettings(
        _ settings: [String: SettingValue], activity: [String], live: Bool
    ) -> [String: SettingValue] {
        var result = settings
        if !activity.isEmpty {
            result[QAOptions.appsActivityKey] = .string(activity.joined(separator: ","))
        }
        if live {
            result[QAOptions.appsLiveActivityKey] = .bool(true)
        } else if result[QAOptions.appsLiveActivityKey] == nil {
            result[QAOptions.appsLiveActivityKey] = .bool(false)
        }
        return result
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
            Logger(subsystem: "com.lintelapp", category: "app")
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
