import Foundation
import LintelKit
import LintelSpeech
import Testing

@testable import NotesPlugin

@MainActor
@Suite(.timeLimit(.minutes(1))) struct NotesPaneModelTests {
    private let large: UInt64 = 64 << 30
    private let small = LLMModelCatalog.qwen3Small
    private let big = LLMModelCatalog.qwen3Large

    final class Picker: NotesExportDestinationPicking {
        var answer: URL?
        private(set) var asked: [String] = []
        func chooseDestination(suggestedName: String) async -> URL? {
            asked.append(suggestedName)
            return answer
        }
    }

    private struct Boom: Error {}

    private func make(
        installed: Set<String> = [], store: MemorySettings = MemorySettings(), picker: Picker = Picker(),
        export: @escaping @MainActor (URL) async throws -> NotesExporter.Outcome = { _ in throw Boom() },
        erase: @escaping @MainActor () async throws -> Void = {}
    ) -> NotesPaneModel {
        let settings = PluginSettings(pluginID: "notes", store: store)
        return NotesPaneModel(
            settings: settings, preferences: NoteViewPreferences(settings: settings), physicalMemory: large,
            isInstalled: { installed.contains($0.id) }, picker: picker, exportNotes: export, eraseNotes: erase)
    }

    // MARK: The picker defaults

    @Test func withNothingInstalledTheCatalogDefaultIsShownAsNotInstalled() async {
        let model = make()
        await model.refresh()
        #expect(model.selectedID == LLMModelCatalog.defaultModel.id)
        #expect(model.choiceState == .notInstalled)
        #expect(model.choices.map(\.id) == [LLMModelCatalog.defaultModel.id])
    }

    @Test func theFirstInstalledModelIsTheDefaultWhenNothingIsStored() async {
        let model = make(installed: [big.id])
        await model.refresh()
        #expect(model.selectedID == big.id)
        #expect(model.choiceState == .installed)
        #expect(model.choices.map(\.id) == [big.id])
    }

    @Test func aStoredChoiceWinsAndTheInstalledOnesAreOffered() async {
        let store = MemorySettings()
        store.setValue(.string(big.id), forKey: "plugins.notes.builtInLLMModel")
        let model = make(installed: [small.id], store: store)
        await model.refresh()
        #expect(model.selectedID == big.id)
        #expect(model.choiceState == .notInstalled)
        #expect(Set(model.choices.map(\.id)) == [small.id, big.id])
    }

    @Test func aStoredIdThatLeftTheCatalogFallsBackToTheSameRule() async {
        let store = MemorySettings()
        store.setValue(.string("gone-model"), forKey: "plugins.notes.builtInLLMModel")
        let model = make(installed: [big.id], store: store)
        await model.refresh()
        #expect(model.selectedID == big.id)
    }

    @Test func choosingWritesTheKeyAndAnUnknownIdIsIgnored() async {
        let store = MemorySettings()
        let model = make(installed: [small.id, big.id], store: store)
        await model.refresh()
        #expect(model.selectedID == small.id)
        #expect(store.value(forKey: "plugins.notes.builtInLLMModel") == nil)  // never written until the user chooses
        await model.choose(big.id)
        #expect(store.value(forKey: "plugins.notes.builtInLLMModel") == .string(big.id))
        #expect(model.selectedID == big.id)
        await model.choose("nope")
        #expect(model.selectedID == big.id)
    }

    // MARK: Details toggles

    @Test func theDetailsTogglesWriteTheKeysTheInspectorWrites() {
        let store = MemorySettings()
        let model = make(store: store)
        model.preferences.showAuthorBars = false
        model.preferences.showQuotes = false
        model.preferences.wrapLines = false
        #expect(store.value(forKey: "plugins.notes.showAuthorBars") == .bool(false))
        #expect(store.value(forKey: "plugins.notes.showQuotes") == .bool(false))
        #expect(store.value(forKey: "plugins.notes.wrapLines") == .bool(false))
    }

    // MARK: Export and erase

    @Test func cancellingTheFolderPanelExportsNothing() async {
        let picker = Picker()
        let model = make(
            picker: picker,
            export: { _ in
                Issue.record("exported")
                throw Boom()
            })
        await model.exportAll()
        #expect(picker.asked.count == 1)
        #expect(model.message == nil)
        #expect(!model.isExporting)
    }

    @Test func aSuccessfulExportSaysHowManyAndWhere() async {
        let picker = Picker()
        picker.answer = URL(filePath: "/tmp/x/Lintel Notes")
        let model = make(picker: picker, export: { url in .init(folder: url, noteCount: 3) })
        await model.exportAll()
        #expect(model.message == NotesPaneModel.exported(count: 3, folder: "Lintel Notes"))
        #expect(!model.isFailure)
    }

    @Test func aFailedExportAndAFailedEraseAreReportedAsFailures() async {
        let picker = Picker()
        picker.answer = URL(filePath: "/tmp/x/Lintel Notes")
        let model = make(picker: picker, erase: { throw Boom() })
        await model.exportAll()
        #expect(model.isFailure)
        let first = model.message
        await model.erase()
        #expect(model.isFailure)
        #expect(model.message != first)
    }

    @Test func eraseRunsTheErase() async {
        var erased = 0
        let model = make(erase: { erased += 1 })
        await model.erase()
        #expect(erased == 1)
        #expect(!model.isFailure)
        #expect(model.message != nil)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct NotesPluginSettingsTests {
    @Test func theSettingsPaneTouchesNoKeychainAndNoFile() {
        let keychain = CountingKeychain()
        let storage = FileManager.default.temporaryDirectory.appending(
            path: "lintel-notes-pane-\(UUID().uuidString)", directoryHint: .isDirectory)
        let plugin = NotesPlugin(context: makeContext(storage: storage, keychain: keychain))
        #expect(plugin.settingsPane() != nil)
        #expect(plugin.modelUsage.count == 1)
        #expect(plugin.modelUsage[0].isRequired == false)
        #expect(plugin.modelUsage[0].kind == .llm)
        #expect(keychain.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: storage.path))
    }

    @Test func eraseNotesDataRemovesOnlyNotesDataAndDropsOpenDocuments() async throws {
        let keychain = MemoryKeychain()
        let root = FileManager.default.temporaryDirectory.appending(
            path: "lintel-notes-erase-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appending(path: "notes", directoryHint: .isDirectory)
        let meetings = root.appending(path: "meetings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        try Data("m".utf8).write(to: meetings.appending(path: "meetings.sqlite"))
        let plugin = NotesPlugin(context: makeContext(storage: storage, keychain: keychain))
        plugin.library.open()
        try #require(plugin.library.store).insertDocument(.manual("a"))
        #expect(FileManager.default.fileExists(atPath: storage.path))

        try await plugin.eraseNotesData()
        #expect(!FileManager.default.fileExists(atPath: storage.path))
        #expect(keychain.itemNames.isEmpty)
        #expect(FileManager.default.fileExists(atPath: meetings.appending(path: "meetings.sqlite").path))
        #expect(plugin.library.store == nil)
    }

    /// Settings → Features → Erase Data goes through `eraseData()` (deactivate, erase, activate): the open
    /// documents' writers hold the erased store and are dropped like in "Erase Notes Data…", so a note written
    /// afterwards lands in the new library instead of a closed one.
    @Test func eraseDataFromFeaturesDropsTheOpenDocumentsToo() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "lintel-notes-erase-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = NotesPlugin(context: makeContext(storage: root, keychain: MemoryKeychain()))
        try await plugin.activate()
        await plugin.workspace.refresh()
        await plugin.workspace.newNote()
        #expect(!plugin.documents.documentIDs.isEmpty)

        await plugin.deactivate()
        try await plugin.eraseData()
        try await plugin.activate()
        #expect(plugin.documents.documentIDs.isEmpty)
        #expect(plugin.library.store == nil)

        await plugin.workspace.newNote()
        #expect(plugin.workspace.rows.count == 1)
        await plugin.deactivate()
    }

    /// Export All Notes on a Mac where Notes never stored anything: nothing to export, and neither the Keychain
    /// item nor `notes.sqlite` is created by asking (the lazy-store rule).
    @Test func exportOnAFreshProfileCreatesNoKeychainItemAndNoFile() async throws {
        let keychain = CountingKeychain()
        let root = FileManager.default.temporaryDirectory.appending(
            path: "lintel-notes-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appending(path: "notes", directoryHint: .isDirectory)
        let plugin = NotesPlugin(context: makeContext(storage: storage, keychain: keychain))
        await #expect(throws: NotesExporter.Failure.nothingToExport) {
            _ = try await plugin.exportAllNotes(to: root.appending(path: "Export", directoryHint: .isDirectory))
        }
        #expect(keychain.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: storage.path))
    }
}
