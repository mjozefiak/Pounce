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

    public var workspaceSections: [WorkspaceSection] {
        [notesSection]
    }

    /// The Notes section of the main window. A stub: it lists the QA fixtures (`--qa-notes`, DEBUG) or says there
    /// are no notes yet. The explorer, tabs and document come with Phase 3.
    var notesSection: WorkspaceSection {
        let fixtures = qaFixtures
        return WorkspaceSection(
            id: "notes",
            title: LocalizedStringResource("Notes", comment: "Main window section title"),
            symbolName: "note.text",
            order: Self.manifest.order
        ) {
            AnyView(NotesSectionStub(notes: fixtures))
        }
    }

    var qaFixtures: [NoteSummary] {
        #if DEBUG
        context.settings.bool(NotesSettingsKey.qaFixtures, default: false) ? NotesQAFixtures.summaries : []
        #else
        []
        #endif
    }
}
