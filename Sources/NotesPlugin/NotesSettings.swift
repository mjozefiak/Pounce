import Foundation
import LintelKit
import LintelSpeech

/// `plugins.notes.*`: every key is declared here and nowhere else (a protected contract from the release that
/// ships Notes, `BACKWARD_COMPATIBILITY.md` section 3). `plugins.notes.enabled` is host-owned and always true.
enum NotesSettingsKey {
    /// `time` or `source`, default `time`.
    static let grouping = "grouping"
    static let showAuthorBars = "showAuthorBars"
    static let showQuotes = "showQuotes"
    static let showComments = "showComments"
    static let wrapLines = "wrapLines"
    /// Width of the explorer and of the inspector in whole points, set by dragging their dividers; 0 or missing
    /// means the default width (a double-click on the divider writes 0).
    static let explorerWidth = "explorerWidth"
    static let inspectorWidth = "inspectorWidth"
    /// An `LLMModelCatalog` id; default: the first installed model, else the catalog default.
    static let builtInLLMModel = "builtInLLMModel"
    /// HIDDEN, no UI: the editor is read-only and no revision is ever written; export, copy and delete still
    /// work. Written only by the user or on a support instruction.
    static let readOnly = "readOnly"
    #if DEBUG
    /// DEBUG only, set by `--qa-notes`: the Notes section lists fixture notes. Not a contract.
    static let qaFixtures = "qaFixtures"
    /// DEBUG only: note keys to open in tabs when the section is built, comma separated, each optionally with
    /// `@<layer id>` for the layer to show (`--qa-setting plugins.notes.qaOpen=meetings:<id>@transcript`).
    static let qaOpen = "qaOpen"
    /// DEBUG only, with `--qa-notes`: shows one whole-section state: `loading` (never finishes reading), `empty`
    /// (no notes, recording on), `off` (no recording plugin), `locked` (nothing readable, `notes.sqlite` locked),
    /// `locked-rows` (the sources are listed, `notes.sqlite` is locked), `save-error` (the save-error strip).
    static let qaState = "qaState"
    /// DEBUG only, with `--qa-notes`: shows the open note in the editor (step 4.1, before saving exists in 4.2): `on`,
    /// or `readonly` for the editor as `plugins.notes.readOnly` shows it. Nothing is saved.
    static let qaEditor = "qaEditor"
    /// DEBUG only, with `--qa-notes`: `raw` starts every editor in Raw (plain monospaced Markdown). Not a contract.
    static let qaEditorMode = "qaEditorMode"
    /// DEBUG only, with `--qa-notes`: `mixed` draws the agent's layers with one block added by the user and one
    /// revised by the agent (step 4.3), so the gutter, the marks and the chip rule can be looked at without a store.
    static let qaAttribution = "qaAttribution"
    /// DEBUG only, with `--qa-notes`: `new` presses ⌘N once the list is in, `written` creates a manual note with a
    /// title and some text (step 4.4). The store is the QA run's own. Not a contract.
    static let qaManual = "qaManual"
    /// DEBUG only, with `--qa-notes`: `history` gives the fixture meeting's notes an agent revision and two of yours
    /// in the QA run's own `notes.sqlite` and shows History (step 4.5); `compare` also opens the comparison.
    static let qaHistory = "qaHistory"
    /// DEBUG only, with `--qa-notes`: `threads` gives the fixture meeting's notes two open comments and a resolved one
    /// in the QA run's own store and opens the note in the editor with the Comments tab (step 5.2); `popover` also opens
    /// the new-comment popover on a selection; `changed` makes one comment's text disappear ("Text changed").
    static let qaComments = "qaComments"
    /// DEBUG only, with `--qa-notes` and `qaComments`: shows the revise run's lock and report strips without a model
    /// (step 6.2): `waiting` ("Waiting for the model"), `writing` (the lock strip, the editor read-only), `done`,
    /// `skipped`, `rejected`, `conflict`, `timedOut`, `needsModel`. Nothing runs and nothing is written.
    static let qaRevise = "qaRevise"
    /// DEBUG only, with `--qa-notes`: opens the command palette once the list is in (step 7.1); the value is what is
    /// typed into it (`open` for nothing). Not a contract.
    static let qaPalette = "qaPalette"
    /// DEBUG only, with `--qa-notes`: `on` starts with "Hide content" on (step 7.1). Not a contract.
    static let qaHidden = "qaHidden"
    /// DEBUG only, with `--qa-notes`: `meeting`, `dictation`, `manual` or `copy` opens that delete confirmation sheet
    /// (step 4.6). Nothing is deleted unless the sheet is confirmed.
    static let qaDelete = "qaDelete"
    /// DEBUG only: text typed into the explorer's search field once the first list is in.
    static let qaSearch = "qaSearch"
    #endif
}

/// Typed reads of `plugins.notes.*`. Reads only; nothing here opens a store.
struct NotesSettings: Sendable {
    enum Grouping: String, Sendable { case time, source }

    static let defaultGrouping = Grouping.time

    private let settings: PluginSettings

    init(_ settings: PluginSettings) {
        self.settings = settings
    }

    var grouping: Grouping { settings.string(NotesSettingsKey.grouping).flatMap(Grouping.init) ?? Self.defaultGrouping }
    var showAuthorBars: Bool { settings.bool(NotesSettingsKey.showAuthorBars, default: true) }
    var showQuotes: Bool { settings.bool(NotesSettingsKey.showQuotes, default: true) }
    var showComments: Bool { settings.bool(NotesSettingsKey.showComments, default: true) }
    var wrapLines: Bool { settings.bool(NotesSettingsKey.wrapLines, default: true) }
    /// Whole points; 0 is the default width.
    var explorerWidth: Int { settings.integer(NotesSettingsKey.explorerWidth, default: 0) }
    var inspectorWidth: Int { settings.integer(NotesSettingsKey.inspectorWidth, default: 0) }

    /// Hidden: the editor is read-only and no revision is written.
    var readOnly: Bool { settings.bool(NotesSettingsKey.readOnly, default: false) }

    /// The stored model id, if any.
    var storedModelID: String? { settings.string(NotesSettingsKey.builtInLLMModel) }

    /// The model Notes uses: the stored one while it is still in the catalog, else the first catalog model that
    /// is installed, else the catalog default (one rule, also for the settings key).
    func builtInLLMModel(installedIDs: Set<String>) -> LLMModel {
        if let stored = storedModelID.flatMap({ LLMModelCatalog.model(id: $0) }) { return stored }
        return LLMModelCatalog.all.first { installedIDs.contains($0.id) } ?? LLMModelCatalog.defaultModel
    }
}
