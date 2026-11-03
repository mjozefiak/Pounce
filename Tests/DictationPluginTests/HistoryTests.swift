import Foundation
import GRDB
import PounceCore
import PounceKit
import PouncePersistence
import Synchronization
import Testing
import os

@testable import DictationPlugin

private func keys(_ byte: UInt8 = 9) throws -> MasterKeys {
    try #require(MasterKeys(master: Data(repeating: byte, count: 32)))
}

private func entry(
    _ raw: String, formatted: String? = nil, at seconds: TimeInterval = 1_000_000, mode: FormatMode? = nil
) -> DictationEntry {
    DictationEntry(
        createdAt: Date(timeIntervalSince1970: seconds), durationMs: 4_000, rawText: raw, formattedText: formatted,
        formatMode: mode ?? (formatted == nil ? .raw : .clean), formatStatus: formatted == nil ? .none : .ok,
        detectedLanguages: "pl", speechModelID: "parakeet-ultra", formatterModel: nil,
        targetBundleID: "com.apple.TextEdit", pasteResult: .pasted)
}

@Suite struct DictationStoreTests {
    private func store() throws -> (DictationStore, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        return (try DictationStore.open(in: directory.url, keys: keys()), directory)
    }

    @Test func aNewDatabaseIsEmptyEncryptedAndPrivate() throws {
        let (store, directory) = try store()
        #expect(try store.count() == 0)
        try store.close()
        let file = directory.url.appending(path: "dictation.sqlite")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // Without the key the file is not a database.
        #expect(throws: (any Error).self) { _ = try DatabaseQueue(path: file.path) }
        // The file does not hold the text in the clear.
        let (again, other) = try self.store()
        defer { withExtendedLifetime(other) {} }
        try again.insert(entry("a very recognisable secret sentence"))
        try again.close()
        let bytes = try Data(contentsOf: other.url.appending(path: "dictation.sqlite"))
        #expect(bytes.range(of: Data("recognisable".utf8)) == nil)
    }

    @Test func insertsAndListsNewestFirst() throws {
        let (store, directory) = try store()
        defer { withExtendedLifetime(directory) {} }
        try store.insert(entry("pierwszy", at: 100))
        try store.insert(entry("drugi", formatted: "Drugi.", at: 300))
        try store.insert(entry("trzeci", at: 200))
        #expect(try store.recent(limit: 10).map(\.rawText) == ["drugi", "trzeci", "pierwszy"])
        let second = try #require(try store.recent(limit: 1).first)
        #expect(second.formattedText == "Drugi.")
        #expect(second.bestText == "Drugi.")
        #expect(second.targetBundleID == "com.apple.TextEdit")
        #expect(second.durationMs == 4_000)
        #expect(try store.entry(second.id)?.rawText == "drugi")
        #expect(try store.entry(999) == nil)
    }

    @Test func filtersSeparateFormattedFromRaw() throws {
        let (store, directory) = try store()
        defer { withExtendedLifetime(directory) {} }
        try store.insert(entry("raw only", at: 1))
        try store.insert(entry("cleaned", formatted: "Cleaned.", at: 2))
        #expect(try store.recent(limit: 10, filter: .formatted).map(\.rawText) == ["cleaned"])
        #expect(try store.recent(limit: 10, filter: .raw).map(\.rawText) == ["raw only"])
        #expect(try store.recent(limit: 10, filter: .all).count == 2)
    }

    @Test func fullTextSearchCoversRawAndFormattedTextByPrefix() throws {
        let (store, directory) = try store()
        defer { withExtendedLifetime(directory) {} }
        try store.insert(entry("jutro spotkanie w biurze", formatted: "Jutro mamy spotkanie w biurze.", at: 1))
        try store.insert(entry("kupić mleko i chleb", at: 2))
        #expect(try store.search("spotk", limit: 10).count == 1)
        #expect(try store.search("mamy", limit: 10).count == 1)  // only in the formatted text
        #expect(try store.search("chl mle", limit: 10).count == 1)
        #expect(try store.search("nieistniejące", limit: 10).isEmpty)
        #expect(try store.search("mleko", limit: 10, filter: .formatted).isEmpty)
        #expect(try store.search("", limit: 10).isEmpty)
    }

    @Test func theIndexFollowsDeletes() throws {
        let (store, directory) = try store()
        defer { withExtendedLifetime(directory) {} }
        let id = try store.insert(entry("unikalne słowo kluczowe"))
        #expect(try store.search("unikalne", limit: 5).count == 1)
        try store.delete([id])
        #expect(try store.search("unikalne", limit: 5).isEmpty)
        try store.insert(entry("coś"))
        try store.deleteAll()
        #expect(try store.count() == 0)
    }

    @Test func retentionRemovesOldAndSurplusEntries() throws {
        let (store, directory) = try store()
        defer { withExtendedLifetime(directory) {} }
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 100 * day)
        for age in [40, 31, 10, 5, 3, 2, 1] {
            try store.insert(entry("wpis \(age)", at: now.timeIntervalSince1970 - Double(age) * day))
        }
        #expect(try store.applyRetention(cutoff: now.addingTimeInterval(-30 * day), maximumCount: 500) == 2)
        #expect(try store.count() == 5)
        #expect(try store.applyRetention(cutoff: now.addingTimeInterval(-30 * day), maximumCount: 3) == 2)
        #expect(try store.recent(limit: 10).map(\.rawText) == ["wpis 1", "wpis 2", "wpis 3"])
    }

    @Test func aClosedStoreThrowsInsteadOfCrashing() throws {
        let (store, directory) = try store()
        defer { withExtendedLifetime(directory) {} }
        try store.close()
        try store.close()
        #expect(throws: DictationStoreError.self) { try store.count() }
        #expect(throws: DictationStoreError.self) { try store.insert(entry("x")) }
    }

    @Test func theWrongKeyDoesNotOpenTheDatabase() throws {
        let directory = try TemporaryDirectory()
        let first = try DictationStore.open(in: directory.url, keys: keys(1))
        try first.insert(entry("tajne"))
        try first.close()
        #expect(throws: (any Error).self) { try DictationStore.open(in: directory.url, keys: keys(2)) }
    }
}

@MainActor
@Suite struct DictationHistoryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func make(
        _ keychain: MemoryKeychain = MemoryKeychain(), settings: [String: SettingValue] = [:]
    ) throws -> (DictationHistory, DictationSettings, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let store = MemorySettingsStore(settings)
        let dictationSettings = DictationSettings(PluginSettings(pluginID: "dictation", store: store))
        let now = now
        let history = DictationHistory(
            directory: directory.url, keychain: keychain, settings: dictationSettings, clock: ContinuousClock(),
            now: { now }, runsRetentionJob: false, logger: Logger(subsystem: "app.pounce.tests", category: "dictation"))
        return (history, dictationSettings, directory)
    }

    private func waitForCount(_ history: DictationHistory, _ count: Int) async throws {
        for _ in 0..<300 {
            history.refreshCount()
            if history.entryCount == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func theFirstOpenCreatesTheKeyAndRecordingWorks() async throws {
        let keychain = MemoryKeychain()
        let (history, _, directory) = try make(keychain)
        defer { withExtendedLifetime(directory) {} }
        history.open()
        #expect(history.status == .ready)
        #expect(keychain.itemNames == ["app.pounce.dictation/master-key"])
        history.record(entry("pierwsze dyktowanie", at: now.timeIntervalSince1970 - 10))
        try await waitForCount(history, 1)
        #expect(history.entryCount == 1)
        history.close()
        #expect(history.status == .closed)
    }

    @Test func switchedOffNothingIsOpenedOrRecorded() async throws {
        let keychain = MemoryKeychain()
        let (history, _, directory) = try make(keychain, settings: ["plugins.dictation.historyEnabled": .bool(false)])
        defer { withExtendedLifetime(directory) {} }
        history.open()
        #expect(history.status == .closed)
        #expect(keychain.itemNames.isEmpty)
        history.record(entry("nic"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(history.entryCount == 0)
    }

    @Test func aLockedKeychainDisablesTheHistoryWithoutDeletingAnything() async throws {
        let keychain = MemoryKeychain()
        let (seed, _, directory) = try make(keychain)
        defer { withExtendedLifetime(directory) {} }
        seed.open()
        seed.record(entry("zostaje"))
        try await waitForFile(directory)
        seed.close()
        let before = try Data(contentsOf: directory.url.appending(path: "dictation.sqlite"))

        keychain.state.withLock { $0.readError = .interactionNotAllowed }
        let (history, _, _) = try makeInSameFolder(directory, keychain)
        history.open()
        #expect(history.status == .unavailable(.locked))
        #expect(try Data(contentsOf: directory.url.appending(path: "dictation.sqlite")) == before)
        #expect(history.store == nil)
    }

    @Test func aMissingKeyArchivesTheOldDatabaseAndStartsAgain() async throws {
        let keychain = MemoryKeychain()
        let (seed, _, directory) = try make(keychain)
        defer { withExtendedLifetime(directory) {} }
        seed.open()
        seed.record(entry("stare"))
        try await waitForCount(seed, 1)
        seed.close()

        keychain.state.withLock { $0.items.removeAll() }
        let (history, _, _) = try makeInSameFolder(directory, keychain)
        history.open()
        #expect(history.status == .ready)
        #expect(history.entryCount == 0)
        let archive = try #require(history.resetArchive)
        #expect(archive.lastPathComponent.hasPrefix("dictation.sqlite.unreadable-"))
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(keychain.itemNames == ["app.pounce.dictation/master-key"])
    }

    @Test func clearRetentionAndEraseWork() async throws {
        let keychain = MemoryKeychain()
        let (history, settings, directory) = try make(keychain)
        defer { withExtendedLifetime(directory) {} }
        history.open()
        let day: TimeInterval = 86_400
        history.record(entry("stare", at: now.timeIntervalSince1970 - 40 * day))
        history.record(entry("nowe", at: now.timeIntervalSince1970 - day))
        try await waitForCount(history, 2)
        #expect(settings.retentionDays == 30)
        #expect(history.applyRetention() == 1)
        #expect(history.entryCount == 1)
        try history.clear()
        #expect(history.entryCount == 0)
        try history.erase()
        #expect(history.status == .closed)
        #expect(keychain.itemNames.isEmpty)
        // Erasing again, with no key, is not an error.
        try history.erase()
    }

    // MARK: Helpers

    private func waitForFile(_ directory: TemporaryDirectory) async throws {
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: directory.url.appending(path: "dictation.sqlite").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    private func makeInSameFolder(_ directory: TemporaryDirectory, _ keychain: MemoryKeychain) throws -> (
        DictationHistory, DictationSettings, TemporaryDirectory
    ) {
        let settings = DictationSettings(PluginSettings(pluginID: "dictation", store: MemorySettingsStore()))
        let now = now
        let history = DictationHistory(
            directory: directory.url, keychain: keychain, settings: settings, clock: ContinuousClock(),
            now: { now }, runsRetentionJob: false, logger: Logger(subsystem: "app.pounce.tests", category: "dictation"))
        return (history, settings, directory)
    }
}

@Suite struct DictationHistorySourceTests {
    private func rig() throws -> (DictationHistorySource, DictationStore, PastedLog, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let store = try DictationStore.open(in: directory.url, keys: keys())
        let log = PastedLog()
        let source = DictationHistorySource(
            store: { store }, paste: { log.add($0) }, delete: { try store.delete([$0]) },
            now: { Date(timeIntervalSince1970: 1_000_100) })
        return (source, store, log, directory)
    }

    private func query(_ text: String) -> NormalizedQuery {
        NormalizedQuery(raw: text, normalized: TextNormalizer.prepare(text).normalized)
    }

    @Test func anEmptyQueryListsNewestFirstAndKeepsTheOrder() async throws {
        let (source, store, _, directory) = try rig()
        defer { withExtendedLifetime(directory) {} }
        try store.insert(entry("najstarszy wpis", at: 1_000_000))
        try store.insert(entry("najnowszy wpis", formatted: "Najnowszy wpis.", at: 1_000_050))
        let found = try await source.search(query(""), filter: nil, limit: 10)
        #expect(found.map(\.title) == ["Najnowszy wpis.", "najstarszy wpis"])
    }

    @Test func filtersAndQueriesNarrowTheList() async throws {
        let (source, store, _, directory) = try rig()
        defer { withExtendedLifetime(directory) {} }
        try store.insert(entry("kupić mleko", at: 1_000_000))
        try store.insert(entry("spotkanie jutro", formatted: "Spotkanie jutro.", at: 1_000_010))
        #expect(try await source.search(query(""), filter: "formatted", limit: 10).count == 1)
        #expect(try await source.search(query(""), filter: "raw", limit: 10).count == 1)
        #expect(try await source.search(query(""), filter: "all", limit: 10).count == 2)
        let found = try await source.search(query("mleko"), filter: nil, limit: 10)
        #expect(found.map(\.title) == ["kupić mleko"])
    }

    @Test func aWordOnlyInTheRawTextIsFoundByFullText() async throws {
        let (source, store, _, directory) = try rig()
        defer { withExtendedLifetime(directory) {} }
        try store.insert(entry("yyy zadzwonić do Marka", formatted: "Zadzwonić do Marka.", at: 1_000_000))
        let found = try await source.search(query("yyy"), filter: nil, limit: 10)
        #expect(found.count == 1)
    }

    @Test func actionsPasteTheFormattedTheRawTextAndDelete() async throws {
        let (source, store, log, directory) = try rig()
        defer { withExtendedLifetime(directory) {} }
        try store.insert(entry("surowy tekst", formatted: "Czysty tekst.", at: 1_000_000))
        let candidate = try #require(try await source.search(query(""), filter: nil, limit: 5).first)
        let actions = source.actions(for: candidate)
        #expect(
            actions.map(\.id) == ["dictation.history.paste", "dictation.history.pasteRaw", "dictation.history.delete"])
        #expect(actions[1].shortcut == KeyShortcut(key: "\r", modifiers: .command))
        #expect(actions[2].shortcut == KeyShortcut(key: "x", modifiers: .control))
        #expect(actions[2].keepsPanelOpen)
        let context = ActionContext(previousApp: nil, panel: NoPanel())
        try await actions[0].perform(context)
        try await actions[1].perform(context)
        #expect(log.all == ["Czysty tekst.", "surowy tekst"])
        try await actions[2].perform(context)
        #expect(try store.count() == 0)
    }

    @Test func titlesUseTheFirstSentence() {
        let long = entry("to jest pierwsze zdanie. a to drugie zdanie, którego nie widać")
        #expect(DictationPresentation.title(long) == "to jest pierwsze zdanie.")
        #expect(DictationPresentation.title(entry("tak. nie")) == "tak. nie")
        #expect(DictationPresentation.entryID(DictationPresentation.itemKey(42)) == 42)
        #expect(DictationPresentation.entryID(ItemKey(pluginID: "files", key: "entry:1")) == nil)
    }
}

final class PastedLog: Sendable {
    private let inner = Mutex<[String]>([])
    func add(_ text: String) { inner.withLock { $0.append(text) } }
    var all: [String] { inner.withLock { $0 } }
}

struct NoPanel: PanelPresenter {
    @MainActor func hidePanel() {}
    @MainActor func showConfirmation(_ message: LocalizedStringResource) {}
}
