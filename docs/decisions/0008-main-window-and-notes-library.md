# ADR 0008: Main window, workspace sections and the notes library contract

- Status: accepted by the owner on 2026-11-04 (design and the decisions below); the Phase 0 spike in the Notes spec may amend the editor choice.
- Date: 2026-11-04
- Specs: `.ai/specs/2026-11-04-lintel-main-window.md`, `.ai/specs/2026-11-04-notes-workspace.md`
- Surfaces touched: `LintelKit` (protected contract, `BACKWARD_COMPATIBILITY.md` §1), a new encrypted store (§2), new settings keys (§3), launcher behaviour (§5). `risk-high` follows the SDLC definition (contract, store, migrations, Keychain).

## Context

Lintel has no window other than Settings, so notes and dictation history live only as launcher list modes and a per-meeting window. The owner wants a main window opened by the Dock icon, a Notes library with editing, comments and a history of who wrote what, notes that exist without any recording, and a local model that can revise commented text. Plugins may not import each other or `LintelApp`, `LintelApp` owns no data, and recorded content sits in two encrypted databases with their own Keychain items.

## Decision

1. **Window and sections.** `LintelApp` owns one `MainWindowController`. Plugins contribute **sections** through an additive `LintelPlugin.workspaceSections` (empty default). Settings is a mode of the same window, not a second window.
2. **Contract additions, all additive with defaults:** `WorkspaceSection` (with `handleClose`), `SettingsStatus` (`settingsStatus`), `ModelUsage` (`modelUsage`), `ResultAction.confirmation`, `PluginManifest.canBeDisabled` (default true, enforced by the host) and `settingsGroup`, `Permission.isReadable`, `NoteSource` and the optional `NoteSourceEditing` (`noteSources`), and `PluginContext.noteSources` / `noteSourcesChanged` / `openNote` (returns `Bool`) / `availableCommands` / `openModels`, and `PasteboardClient.write(_:options:)`. Open sets (`NoteKind`, `NoteAuthor`, `NoteMatch`, `ModelKind`, `SettingsGroup`) are `RawRepresentable` structs so new values are additive. `LintelPlugin.settingsPane()` keeps its signature, with one added rule: it may be called while the plugin is inactive or failed and must only read settings.
3. **New plugin `NotesPlugin`** (`PluginID` `notes`, always on) owns manual notes, a settings pane (model choice, export, erase), **revisions** (author `stt` / `agent` / `human`), **comments** and the search index in its own SQLCipher `notes.sqlite` (`MasterKeyStore(service: com.lintelapp.notes)`, the same Keychain policy as Clipboard, Dictation and Meetings).
4. **Recorded content stays with its owner.** `MeetingsPlugin` and `DictationPlugin` implement `NoteSource`; Notes keeps an **overlay** (document + revisions + comments) per note key, seeded on first edit **per layer** (meetings: notes, transcript; dictation: cleaned, original), so each layer is overlaid independently and the transcript stays editable. Note keys are stable across Erase Data and key resets (`meeting.uuid`; a dictation store id derived from the store's own key, plus the row id), and an overlay whose source `startedAt` changes is detached, never re-attached. The source's text is never rewritten by Notes.
5. **The agent is the local built-in model** (`LLMLease`, background priority, no network) and may change **only blocks that carry a comment**; a block the user edited after the comment is skipped; the document is read-only during a run; regeneration of an edited note is a *proposal* the user applies or discards.
6. **Provenance is part of the product.** Every block shows its author; source-quote chips ("checked against the recording") stay only on untouched agent blocks.
7. **Launcher:** the panel stays as is, except that destructive row actions ask for a second ⌃X (owner decision, against the author's recommendation).

## Alternatives rejected

- Move recorded notes into `notes.sqlite` (migrates encrypted data across keys, widens the blast radius of a Keychain error).
- Write edits back into `meetings.sqlite` (Meetings would have to understand human text; quote verification is lost).
- A shell-owned database (breaks "`LintelApp` is the composition root, not a data owner").
- A separate window per feature, or toolbar tabs for Settings (the problems the audit found).
- Giving the agent whole-document rewrites (it would overwrite the user's writing).
- A new third-party Markdown or editor dependency (Foundation's `AttributedString(markdown:)` and TextKit 2 are enough pending the spike).

## Consequences

- Code layout, state machines (edit lock, revise run) and test seams are specified in the two specs; `MarkdownBlocks.split` lives in `LintelCore` so Meetings and Notes split blocks identically.
- Plugin graph is unchanged: plugins still import only `LintelKit`, `LintelSpeech`, `LintelPersistence`, `LintelCore`; `NotesPlugin` sees other plugins only as `any NoteSource` values supplied by the shell. `LintelApp` gains a dependency on `LintelSpeech` (Models pane, behind a `ModelInventory` port).
- A new protected store and namespace (`notes.sqlite`, `plugins.notes.*`, `app.mainWindow.*`) with additive migrations and the standard key policy.
- Notes data has its own Data section (export all, erase) and the rollback note "export before reverting": `notes.sqlite` is encrypted with a login-keychain key and is not portable to another Mac or user unless the keychain moves with it (for example Migration Assistant).
- Notes of edited text are **never auto-deleted** by retention (they are the user's writing); unedited recorded notes keep their source retention. This keeps data longer than today for edited notes and needs the owner's explicit approval in the PR that ships it (BC §3).
- The meeting window is removed once the reader ships; its frame autosave names go with it.
- Editor feasibility is not proven: Phase 0 of the Notes spec ends with a go / fallback (Markdown source editor plus preview) recorded as an addendum here.

## Release gate

The one rule for both specs: a release tag inside the stack is allowed only while the new window (Dock, ⌘, and "Settings…" routing) and `NotesPlugin` registration are `#if DEBUG`. The main-window spec's step 6.3 removes the window gate with `SettingsWindowController`; the Notes spec's step 7.1 removes the Notes gate. Neither gate is a runtime switch (`--qa-window` and `--qa-notes` exist only in DEBUG). No schema, key or Keychain item of this feature reaches a release before its gate is removed.

## Rollback

The contract and plugin are additive; a revert of the PR stack restores today's behaviour. `notes.sqlite` stays on disk unread (export first). Source stores are not changed by this feature.
