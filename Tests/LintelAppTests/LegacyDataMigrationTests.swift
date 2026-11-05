import Foundation
import Testing

@testable import LintelApp

private final class DictionaryDefaults: DefaultsAccess {
    var values: [String: Any]
    init(_ values: [String: Any] = [:]) { self.values = values }
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

@Suite struct LegacyDataMigrationTests {
    private let fileManager = FileManager.default

    private func makeRoot() throws -> URL {
        let url = fileManager.temporaryDirectory.appending(path: "lintel-migration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func legacy(_ root: URL) -> URL {
        root.appending(path: "Pounce", directoryHint: .isDirectory)  // LEGACY-POUNCE
    }
    private func current(_ root: URL) -> URL { root.appending(path: "Lintel", directoryHint: .isDirectory) }

    private func write(_ text: String, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func text(at url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Folders

    @Test func nothingToMoveWhenTheOldFolderIsMissing() throws {
        let root = try makeRoot()
        defer { try? fileManager.removeItem(at: root) }
        #expect(
            LegacyDataMigration().migrateFolder(legacy: legacy(root), current: current(root)) == .nothingToMove)
        #expect(!fileManager.fileExists(atPath: current(root).path))
    }

    @Test func theOldFolderIsMovedWithItsContents() throws {
        let root = try makeRoot()
        defer { try? fileManager.removeItem(at: root) }
        try write("ranking", to: legacy(root).appending(path: "ranking.sqlite"))
        try write("history", to: legacy(root).appending(path: "Plugins/clipboard/clipboard.sqlite"))
        #expect(LegacyDataMigration().migrateFolder(legacy: legacy(root), current: current(root)) == .moved)
        #expect(text(at: current(root).appending(path: "ranking.sqlite")) == "ranking")
        #expect(text(at: current(root).appending(path: "Plugins/clipboard/clipboard.sqlite")) == "history")
        #expect(!fileManager.fileExists(atPath: legacy(root).path))
    }

    @Test func anEmptyNewFolderIsReplaced() throws {
        let root = try makeRoot()
        defer { try? fileManager.removeItem(at: root) }
        try write("ranking", to: legacy(root).appending(path: "ranking.sqlite"))
        try fileManager.createDirectory(at: current(root), withIntermediateDirectories: true)
        try write("", to: current(root).appending(path: ".DS_Store"))
        #expect(LegacyDataMigration().migrateFolder(legacy: legacy(root), current: current(root)) == .moved)
        #expect(text(at: current(root).appending(path: "ranking.sqlite")) == "ranking")
    }

    @Test func nothingIsMergedOrDeletedWhenBothHoldData() throws {
        let root = try makeRoot()
        defer { try? fileManager.removeItem(at: root) }
        try write("old", to: legacy(root).appending(path: "ranking.sqlite"))
        try write("new", to: current(root).appending(path: "ranking.sqlite"))
        #expect(LegacyDataMigration().migrateFolder(legacy: legacy(root), current: current(root)) == .bothExist)
        #expect(text(at: legacy(root).appending(path: "ranking.sqlite")) == "old")
        #expect(text(at: current(root).appending(path: "ranking.sqlite")) == "new")
    }

    @Test func aSecondRunDoesNothing() throws {
        let root = try makeRoot()
        defer { try? fileManager.removeItem(at: root) }
        try write("ranking", to: legacy(root).appending(path: "ranking.sqlite"))
        let migration = LegacyDataMigration()
        #expect(migration.migrateFolder(legacy: legacy(root), current: current(root)) == .moved)
        #expect(migration.migrateFolder(legacy: legacy(root), current: current(root)) == .nothingToMove)
        #expect(text(at: current(root).appending(path: "ranking.sqlite")) == "ranking")
    }

    // MARK: Settings

    @Test func onlyTheAppsOwnKeysAreCopiedAndNothingIsOverwritten() {
        let defaults = DictionaryDefaults([
            "app.textSize": "xl",  // set in the new domain already: stays
            "plugins.files.includeHidden": true,
        ])
        let legacyValues: [String: Any] = [
            "app.textSize": "s",
            "app.hotkey.userDefined": true,
            "plugins.clipboard.paused": true,
            "plugins.files.roots": ["~/Code"],
            "KeyboardShortcuts_mainHotkey": "{\"carbonKeyCode\":49}",
            "NSWindow Frame SettingsWindow": "10 10 600 400",
            "AppleLanguages": ["pl"],
        ]
        let copied = LegacyDataMigration().migrateDefaults(legacy: legacyValues, into: defaults)
        #expect(copied == 4)
        #expect(defaults.values["app.textSize"] as? String == "xl")
        #expect(defaults.values["app.hotkey.userDefined"] as? Bool == true)
        #expect(defaults.values["plugins.clipboard.paused"] as? Bool == true)
        #expect(defaults.values["plugins.files.roots"] as? [String] == ["~/Code"])
        #expect(defaults.values["KeyboardShortcuts_mainHotkey"] as? String != nil)
        #expect(defaults.values["NSWindow Frame SettingsWindow"] == nil)
        #expect(defaults.values["AppleLanguages"] == nil)
        #expect(defaults.values[LegacyDataMigration.migratedKey] as? Bool == true)
    }

    @Test func theSettingsAreCopiedOnlyOnce() {
        let defaults = DictionaryDefaults()
        let migration = LegacyDataMigration()
        #expect(migration.migrateDefaults(legacy: ["app.textSize": "l"], into: defaults) == 1)
        defaults.values["app.textSize"] = nil  // the user changed their mind
        #expect(migration.migrateDefaults(legacy: ["app.textSize": "l"], into: defaults) == 0)
        #expect(defaults.values["app.textSize"] == nil)
    }

    @Test func aFreshInstallStillRecordsThatThereWasNothingToCopy() {
        let defaults = DictionaryDefaults()
        #expect(LegacyDataMigration().migrateDefaults(legacy: nil, into: defaults) == 0)
        #expect(defaults.values[LegacyDataMigration.migratedKey] as? Bool == true)
    }

    // MARK: Whole run

    @Test func runMovesTheFoldersAndCopiesTheSettings() throws {
        let support = try makeRoot()
        let caches = try makeRoot()
        defer {
            try? fileManager.removeItem(at: support)
            try? fileManager.removeItem(at: caches)
        }
        try write("ranking", to: legacy(support).appending(path: "ranking.sqlite"))
        try write("icon", to: legacy(caches).appending(path: "icons/a.png"))
        let defaults = DictionaryDefaults()
        LegacyDataMigration().run(
            supportDirectory: support, cachesDirectory: caches, defaults: defaults,
            legacyDefaults: ["plugins.apps.spotlight": false])
        #expect(text(at: current(support).appending(path: "ranking.sqlite")) == "ranking")
        #expect(text(at: current(caches).appending(path: "icons/a.png")) == "icon")
        #expect(defaults.values["plugins.apps.spotlight"] as? Bool == false)
    }
}
