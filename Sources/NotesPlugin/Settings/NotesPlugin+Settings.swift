import Foundation
import LintelKit
import LintelSpeech
import SwiftUI

/// Settings → Notes (spec "NotesPlugin" `settingsPane()`, main-window spec step 4.1) and the model Notes uses.
extension NotesPlugin {
    /// `Models/llm/`, shared with Dictation and Meetings.
    static let llmDirectoryName = "llm"

    /// Reads settings and the install state of the catalog models only: no store, no Keychain, no download.
    public func settingsPane() -> AnyView? {
        AnyView(NotesSettingsPane(model: paneModel))
    }

    var paneModel: NotesPaneModel {
        if let cached = cachedPaneModel { return cached }
        let manager = ModelManagers.shared.manager(
            for: context.modelsDirectory.appending(path: Self.llmDirectoryName, directoryHint: .isDirectory))
        let model = NotesPaneModel(
            settings: context.settings, preferences: preferences,
            isInstalled: { model in await manager.location(of: model.package).folder != nil },
            exportNotes: { [self] destination in try await exportAllNotes(to: destination) },
            eraseNotes: { [self] in try await eraseNotesData() })
        model.openModelsHandler = context.openModels
        cachedPaneModel = model
        return model
    }

    /// The model that writes and revises notes: the stored choice, else the first installed one, else the catalog
    /// default. Optional for the Models pane (revise and regenerate say "Notes need a model" on demand); it is in
    /// use while a revise run is going on or a lease holds its file (step 6.2, `notesModelUsage`).
    public var modelUsage: [ModelUsage] {
        [notesModelUsage]
    }

    // MARK: Export and erase

    /// "Export All Notes…": every overlay is reconciled with its source first, then the folder is written.
    func exportAllNotes(to destination: URL) async throws -> NotesExporter.Outcome {
        // A profile without a library has nothing to export: opening it here would create the Keychain item and
        // `notes.sqlite` (the lazy-store rule: only a write opens the library).
        guard hasLibrary() else { throw NotesExporter.Failure.nothingToExport }
        // The text still in an open document's buffer belongs in the export.
        await documents.flushAll()
        library.open()
        guard let store = library.store else { throw NotesExporter.Failure.storeUnavailable }
        let environment = workspace.environment
        let clock = context.clock
        var exporter = NotesExporter(store: store)
        exporter.reconcile = { key in await environment.reconcile(key) }
        exporter.title = { key in
            guard let source = await environment.library.source(for: key) else { return nil }
            let outcome = await SourceFanOut.call(budget: SourceFanOut.defaultBudget, clock: clock) {
                try await source.content(for: key)?.summary.title
            }
            if case .value(let title) = outcome { return title }
            return nil
        }
        return try await exporter.export(to: destination)
    }

    /// "Erase Notes Data…", after the confirmation sheet: open documents are dropped without writing, then the
    /// Keychain item and `Plugins/notes/` go. Nothing of Meetings or Dictation is touched.
    func eraseNotesData() async throws {
        documents.discardAll()
        try library.erase()
        await builtWorkspace?.refresh()
    }
}
