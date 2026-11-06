import AppKit
import Foundation
import LintelKit
import LintelSpeech
import LintelUI
import Observation

/// Where Export All asks for the folder. The real one is `NotesExportPanel`; tests use a fake.
protocol NotesExportDestinationPicking {
    /// The folder to create, or `nil` when the user cancelled.
    @MainActor func chooseDestination(suggestedName: String) async -> URL?
}

@MainActor
struct NotesExportPanel: NotesExportDestinationPicking {
    func chooseDestination(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.message = String(
            localized: "Choose where to save the folder with your notes.",
            comment: "Notes settings: message of the Export All Notes save panel")
        panel.prompt = String(localized: "Export", comment: "Notes settings: button of the Export All Notes panel")
        return await panel.begin() == .OK ? panel.url : nil
    }
}

/// What Settings → Notes shows and does (spec "NotesPlugin" `settingsPane()`): the notes model choice, the
/// Details toggles, Export All Notes and Erase Notes Data. It opens no store and starts no work by itself: the
/// model state is read-only (`refresh()` runs when the pane appears) and the store is touched only by an action.
@MainActor @Observable
final class NotesPaneModel {
    struct Choice: Identifiable, Equatable {
        var id: String
        var title: String
    }

    /// The models offered by the picker: the installed ones plus the one in use.
    private(set) var choices: [Choice] = []
    private(set) var selectedID: String
    private(set) var choiceState = ModelChoiceRow.State.notInstalled
    private(set) var selectedTitle: String

    /// The ids found installed by the last `refresh()`.
    private(set) var installedIDs = Set<String>()

    /// `PluginContext.openModels`: the Models pane on a package's row.
    @ObservationIgnored var openModelsHandler: @MainActor (String?) -> Void = { _ in }

    private(set) var isExporting = false
    private(set) var isErasing = false
    /// The result of the last Export or Erase, shown under the Data rows; `isFailure` colours it.
    private(set) var message: String?
    private(set) var isFailure = false

    /// The Details toggles: the same object the inspector uses, so a change shows in an open note at once.
    let preferences: NoteViewPreferences

    @ObservationIgnored private let settings: PluginSettings
    @ObservationIgnored private let physicalMemory: UInt64
    @ObservationIgnored private let isInstalled: @MainActor (LLMModel) async -> Bool
    @ObservationIgnored private let picker: any NotesExportDestinationPicking
    @ObservationIgnored private let exportNotes: @MainActor (URL) async throws -> NotesExporter.Outcome
    @ObservationIgnored private let eraseNotes: @MainActor () async throws -> Void

    init(
        settings: PluginSettings, preferences: NoteViewPreferences,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        isInstalled: @escaping @MainActor (LLMModel) async -> Bool,
        picker: any NotesExportDestinationPicking = NotesExportPanel(),
        exportNotes: @escaping @MainActor (URL) async throws -> NotesExporter.Outcome,
        eraseNotes: @escaping @MainActor () async throws -> Void
    ) {
        self.settings = settings
        self.preferences = preferences
        self.physicalMemory = physicalMemory
        self.isInstalled = isInstalled
        self.picker = picker
        self.exportNotes = exportNotes
        self.eraseNotes = eraseNotes
        let resolved = NotesSettings(settings).builtInLLMModel(installedIDs: [])
        selectedID = resolved.id
        selectedTitle = resolved.package.title
    }

    // MARK: Model

    /// Reads which catalog models are installed and resolves the one in use: the stored choice, else the first
    /// installed model, else the catalog default (`NotesSettings.builtInLLMModel`).
    func refresh() async {
        var installed = Set<String>()
        for model in offered where await isInstalled(model) { installed.insert(model.id) }
        installedIDs = installed
        let current = NotesSettings(settings).builtInLLMModel(installedIDs: installed)
        selectedID = current.id
        selectedTitle = current.package.title
        choiceState = installed.contains(current.id) ? .installed : .notInstalled
        choices = (offered.filter { installed.contains($0.id) || $0.id == current.id }).map {
            Choice(id: $0.id, title: $0.package.title)
        }
    }

    private var offered: [LLMModel] {
        let fits = LLMModelCatalog.available(physicalMemory: physicalMemory)
        return fits.isEmpty ? [LLMModelCatalog.defaultModel] : fits
    }

    func choose(_ id: String) async {
        guard id != selectedID, LLMModelCatalog.model(id: id) != nil else { return }
        settings.set(id, for: NotesSettingsKey.builtInLLMModel)
        await refresh()
    }

    func openModels(_ packageID: String?) { openModelsHandler(packageID) }

    // MARK: Data

    var canExport: Bool { !isExporting && !isErasing }
    var canErase: Bool { !isExporting && !isErasing }

    /// "Export All Notes…": asks for the folder, then writes it. Cancelling the panel changes nothing.
    func exportAll() async {
        guard canExport else { return }
        isExporting = true
        defer { isExporting = false }
        let name = String(
            localized: "Lintel Notes", comment: "Notes settings: suggested name of the folder Export All Notes makes")
        guard let destination = await picker.chooseDestination(suggestedName: name) else { return }
        do {
            let outcome = try await exportNotes(destination)
            report(Self.exported(count: outcome.noteCount, folder: outcome.folder.lastPathComponent), failed: false)
        } catch NotesExporter.Failure.storeUnavailable {
            report(
                String(
                    localized: "Notes can’t be read right now, so nothing was exported.",
                    comment: "Notes settings: Export All failed because the library is locked"), failed: true)
        } catch {
            report(
                String(
                    localized: "The notes couldn’t be exported. Nothing was written.",
                    comment: "Notes settings: Export All failed while writing the folder"), failed: true)
        }
    }

    /// "Erase Notes Data…", after the confirmation sheet.
    func erase() async {
        guard canErase else { return }
        isErasing = true
        defer { isErasing = false }
        do {
            try await eraseNotes()
            report(
                String(
                    localized: "Notes data was erased.",
                    comment: "Notes settings: the result of Erase Notes Data"), failed: false)
        } catch {
            report(
                String(
                    localized: "Notes data couldn’t be erased.",
                    comment: "Notes settings: Erase Notes Data failed"), failed: true)
        }
    }

    private func report(_ text: String, failed: Bool) {
        message = text
        isFailure = failed
    }

    static func exported(count: Int, folder: String) -> String {
        String(
            localized: "\(count) notes exported to “\(folder)”.",
            comment: "Notes settings: the result of Export All Notes, the number of files and the folder name")
    }
}
