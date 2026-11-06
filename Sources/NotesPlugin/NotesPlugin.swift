import Foundation
import LintelKit
import SwiftUI

/// The Notes workspace (spec `.ai/specs/2026-11-04-notes-workspace.md`). Step 1.2 is the skeleton: the manifest and
/// a `notesSection` stub. The plugin is registered in `PluginRegistry` only `#if DEBUG` until step 7.1, so users see
/// nothing of it.
///
/// It never opens a store, reads a file or touches the Keychain before step 4.0, and notes, transcripts and
/// dictation text never reach a log. Other plugins are seen only as `any NoteSource` values the shell hands over
/// (`PluginContext.noteSources`); `NotesPlugin` imports no other plugin.
@MainActor
public final class NotesPlugin: LintelPlugin {
    public nonisolated static let manifest = PluginManifest(
        id: "notes",
        displayName: LocalizedStringResource("Notes", comment: "Plugin name of the Notes workspace"),
        symbolName: "note.text",
        order: 5,
        defaultEnabled: true,
        canBeDisabled: false,
        summary: LocalizedStringResource(
            "Read, edit and comment on your recordings and notes.", comment: "Settings → Features: what Notes does")
    )

    let context: PluginContext

    public init(context: PluginContext) {
        self.context = context
    }

    /// Nothing to start: no store, no file and no Keychain access before step 4.0.
    public func activate() async throws {}

    public func deactivate() async {}

    /// The Notes section's state, built when the section is first shown or a route reaches it.
    private(set) lazy var workspace: NotesWorkspaceModel = makeWorkspace()

    public var workspaceSections: [WorkspaceSection] {
        [notesSection]
    }

    /// The Notes section of the main window: explorer, tabs, path bar, document and status bar (spec step 3.2).
    /// `handleRoute` takes an `openNote` route, `handleClose` closes a tab before the window.
    var notesSection: WorkspaceSection {
        WorkspaceSection(
            id: NotesWorkspaceModel.sectionID,
            title: LocalizedStringResource("Notes", comment: "Main window section title"),
            symbolName: "note.text",
            order: Self.manifest.order,
            makeView: { [self] in AnyView(NotesSectionView(model: workspace)) },
            handleRoute: { [self] route in workspace.handle(route) },
            handleClose: { [self] in workspace.closeCurrentTab() }
        )
    }

    private func makeWorkspace() -> NotesWorkspaceModel {
        let context = context
        let provider = noteSourceProvider
        #if DEBUG
        let locked = qaState == "locked" || qaState == "locked-rows"
        let overlays: any OverlayIndex & OverlayDetacher = locked ? NotesQALockedOverlays() : NoOverlays()
        #else
        let overlays: any OverlayIndex & OverlayDetacher = NoOverlays()
        #endif
        let library = NoteLibrary(sources: provider, overlays: overlays, detacher: overlays)
        let model = NotesWorkspaceModel(
            environment: NotesWorkspaceModel.Environment(
                library: library, pasteboard: context.pasteboard, sourceSetChanges: context.noteSourcesChanged,
                openSettings: context.openSettings, openModels: { context.openModels(nil) }))
        #if DEBUG
        openQAFixtureTabs(in: model)
        applyQAState(to: model)
        #endif
        return model
    }

    #if DEBUG
    private var qaState: String { context.settings.string(NotesSettingsKey.qaState) ?? "" }

    /// `plugins.notes.qaState` and `plugins.notes.qaSearch`: whole-section states and a typed search for QA.
    private func applyQAState(to model: NotesWorkspaceModel) {
        switch qaState {
        case "loading": model.holdsLoading = true
        case "save-error": model.qaShow(.saveFailed)
        default: break
        }
        if let text = context.settings.string(NotesSettingsKey.qaSearch), !text.isEmpty { model.initialSearch = text }
    }

    /// `plugins.notes.qaOpen`: opens the named notes in tabs, the last one current.
    private func openQAFixtureTabs(in model: NotesWorkspaceModel) {
        let list = context.settings.string(NotesSettingsKey.qaOpen) ?? ""
        for entry in list.split(separator: ",") {
            let parts = entry.split(separator: "@", maxSplits: 1).map(String.init)
            guard let raw = parts.first else { continue }
            let route = WorkspaceRoute(kind: NoteRoute.kind, id: raw)
            guard model.handle(route), let id = NoteRoute.itemID(for: route) else { continue }
            if parts.count == 2 { model.preferredLayers[id] = parts[1] }
        }
    }
    #endif

    /// The sources the library reads: the active plugins' (`PluginContext.noteSources`); with `--qa-notes` the
    /// fixture sources come first, so they win over a real plugin of the same id.
    private var noteSourceProvider: @MainActor @Sendable () -> [any NoteSource] {
        let real = context.noteSources
        #if DEBUG
        if context.settings.bool(NotesSettingsKey.qaFixtures, default: false) {
            switch qaState {
            case "off", "locked":
                return { [] }
            default:
                let fixtures = NotesQAFixtureSource.all(empty: qaState == "empty")
                return { fixtures + real() }
            }
        }
        #endif
        return real
    }
}
