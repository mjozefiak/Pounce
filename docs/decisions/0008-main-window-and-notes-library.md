# ADR 0008: Main window, workspace sections and the notes library contract

- Status: accepted by the owner on 2026-11-04 (design and the decisions below); the Phase 0 spike in the Notes spec may amend the editor choice.
- Date: 2026-11-04
- Specs: `.ai/specs/2026-11-04-lintel-main-window.md`, `.ai/specs/2026-11-04-notes-workspace.md`
- Surfaces touched: `LintelKit` (protected contract, `BACKWARD_COMPATIBILITY.md` §1), a new encrypted store (§2), new settings keys (§3), launcher behaviour (§5). `risk-high` follows the SDLC definition (contract, store, migrations, Keychain).

## Context

Lintel has no window other than Settings, so notes and dictation history live only as launcher list modes and a per-meeting window. The owner wants a main window opened by the Dock icon, a Notes library with editing, comments and a history of who wrote what, notes that exist without any recording, and a local model that can revise commented text. Plugins may not import each other or `LintelApp`, `LintelApp` owns no data, and recorded content sits in two encrypted databases with their own Keychain items.

## Decision

1. **Window and sections.** `LintelApp` owns one `MainWindowController`. Plugins contribute **sections** through an additive `LintelPlugin.workspaceSections` (empty default). Settings is a mode of the same window, not a second window.
2. **Contract additions** are those listed in A "Contract additions" and B "Contract additions" (workspace sections, settings status, model usage, `ResultAction.confirmation`, `canBeDisabled`/`settingsGroup`, `NoteSource`/`NoteSourceEditing`, new `PluginContext` members, `PasteboardClient.write(_:options:)`), all additive with defaults; open sets are `RawRepresentable` structs. `LintelPlugin.settingsPane()` keeps its signature, with one added rule: it may be called while the plugin is inactive or failed and must not open stores or make keychain calls (it may read settings and model install state).
3. **New plugin `NotesPlugin`** (`PluginID` `notes`, always on) owns manual notes, a settings pane (model choice, export, erase), **revisions** (author `stt` / `agent` / `human`), **comments** and the search index in its own SQLCipher `notes.sqlite` (`MasterKeyStore(service: com.lintelapp.notes)`, the same Keychain policy as Clipboard, Dictation and Meetings).
4. **Recorded content stays with its owner.** `MeetingsPlugin` and `DictationPlugin` implement `NoteSource`; Notes keeps an **overlay** (document + revisions + comments) per note key, seeded on first edit **per layer** (meetings: notes, transcript; dictation: cleaned, original), so each layer is overlaid independently and the transcript stays editable; each layer has its own `version`, and source changes are reconciled per layer, so a rewrite of one layer never touches the other. Note keys are never reused across Erase Data and key resets (`meeting.uuid`; a dictation store id derived from the store's own key, plus the row id), and an overlay whose source `startedAt` changes is detached, never re-attached, never merged by key with a source note and never handed to a source (its uniqueness is a partial index). The source's text is never rewritten by Notes.
5. **The agent is the local built-in model** (`LLMLease`, background priority, no network) and may change **only blocks that carry a comment**; a block the user edited after the comment is skipped; the document is read-only during a run; regeneration of an edited note is a *proposal* the user applies or discards.
6. **Provenance is part of the product.** Every block shows its author; source-quote chips ("checked against the recording") stay only on untouched agent blocks.
7. **Launcher:** the panel stays as is, except that destructive row actions ask for a second ⌃X (owner decision, against the author's recommendation).
8. **Shared UI target `LintelUI`** (new SwiftPM target, SwiftUI and AppKit, no I/O, no `defaultIsolation`): only what plugin targets need: `LintelBrand`, `BrandPalette`, `TextSize` with the environment value `lintelTextSize`, `SettingsPane` (no banner), `ConfirmSheet`, `ModelChoiceRow` and `settingsHostStyle` (`.legacyWindow` / `.mainWindow`, default `.legacyWindow`). `StatusBanner` (drawn once by the shell's `SettingsHost`) and `PermissionRow` stay in `LintelApp`. It imports `LintelKit` and `LintelCore` only; plugins and `LintelApp` import it; in-tree, not a protected contract. Reason: pane content comes from plugin targets (`settingsPane()`), which cannot import `LintelApp`. The code moves without behaviour change in main-window step 1.6.

## Alternatives rejected

- Move recorded notes into `notes.sqlite` (migrates encrypted data across keys, widens the blast radius of a Keychain error).
- Write edits back into `meetings.sqlite` (Meetings would have to understand human text; quote verification is lost).
- A shell-owned database (breaks "`LintelApp` is the composition root, not a data owner").
- A separate window per feature, or toolbar tabs for Settings (the problems the audit found).
- Giving the agent whole-document rewrites (it would overwrite the user's writing).
- Keeping the components in `LintelApp` (plugin panes could not use them: each plugin would duplicate them, as 92 raw colour uses show today), and putting them in `LintelKit` (that is a contracts-only, protected target).
- A new third-party Markdown or editor dependency (Foundation's `AttributedString(markdown:)` and TextKit 2 are enough pending the spike).

## Consequences

- Code layout, state machines (edit lock, revise run) and test seams are specified in the two specs; `MarkdownBlocks.split` lives in `LintelCore` so Meetings and Notes split blocks identically; the Markdown cleaner and the bidi/control strip move to `LintelCore.MarkdownText` for the same reason.
- Plugin graph gains one shared target: plugins import only `LintelKit`, `LintelSpeech`, `LintelPersistence`, `LintelCore` and `LintelUI` (AGENTS.md "dependencies flow one way" becomes `plugins → LintelUI / LintelSpeech / LintelPersistence / LintelCore → LintelKit`, updated in main-window step 1.6; a package-graph test asserts `LintelUI` imports no plugin and not `LintelApp`; `DependencyRuleTests` lists `LintelUI` and `NotesPlugin`); `NotesPlugin` sees other plugins only as `any NoteSource` values supplied by the shell. `LintelApp` gains a dependency on `LintelSpeech` (Models pane, behind a `ModelInventory` port).
- A new protected store and namespace (`notes.sqlite`, `plugins.notes.*`, `app.mainWindow.*`) with additive migrations and the standard key policy.
- Notes data has its own Data section (export all, erase) and the rollback note "export before reverting" (the export format is defined in B, NotesPlugin): `notes.sqlite` is encrypted with a login-keychain key and is not portable to another Mac or user unless the keychain moves with it (for example Migration Assistant).
- Notes with user writing or an open comment are **never auto-deleted** by retention (they are the user's writing); recorded notes without either keep their source retention. This keeps data longer than today for such notes and needs the owner's explicit approval in the PR that ships it (BC §3).
- The meeting window is removed once the reader ships; its frame autosave names go with it.
- Editor feasibility is not proven: Phase 0 of the Notes spec ends with a go / fallback (Markdown source editor plus preview) recorded as an addendum here.

## Release gate

Terms: **window enabled** = `#if DEBUG` before main-window step 6.3, every build after. **Notes enabled** = `#if DEBUG` before Notes step 7.1, every build after. The specs use only these two terms.

- A release tag inside the stack is allowed only while the window and `NotesPlugin` registration are not enabled in release builds. Neither is a runtime switch (`--qa-window` and `--qa-notes` exist only in DEBUG). No schema, key or Keychain item of this feature reaches a release before its gate is removed.
- While the window is not enabled, release builds keep today's `SettingsWindowController` fully working: `openModels` and `openNote` follow the same gate (`openModels` opens the old controller on the calling plugin's pane when its `modelUsage` lists the package, else the first active plugin that lists it, so "Download Notes Model" and the record flow's model prompt still land on the model card). Panes learn where they are drawn from `settingsHostStyle` (`LintelUI`); they hide model cards, permission rows and in-body status views only for `.mainWindow`. Model removal in the Models pane keeps the plugins' "in use" and removal-reservation guards per model kind (every usage of the kind, not only those listing the package) through `ModelUsage` and evicts the idle warm model first, as today's removal paths do.
- Pane bodies are not gated: each pane PR is releasable in the old window (and the old controller keeps skipping inactive plugins until 6.3).
- Notes enabled (B 7.1) and the removal of `MeetingWindowController` (B 7.3) merge only after A 6.3; B 7.1's PR has a source-scanning test that `MainWindowController` is not inside `#if DEBUG`.

## Rollback

The contract and plugin are additive; a revert of the PR stack restores today's behaviour. `notes.sqlite` stays on disk unread (export first). Source stores are not changed by this feature.
