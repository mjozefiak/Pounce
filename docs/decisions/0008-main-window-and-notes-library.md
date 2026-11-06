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

### Addendum: window enabled in step 6.3 (2026-11-05)

Steps 6.3a to 6.3c enabled the window, the last three commits of the stack. The text above describes the state before them and is kept as written.

- 6.3a removed the `#if DEBUG` gate: the main window, the Dock, ⌘, and "Settings…" routing, `openModels` and `openNote` work in every build. `--qa-window` and `--qa-settings <pane>` stay DEBUG-only QA arguments; `--qa-notes` is unchanged (Notes enabled is still step 7.1).
- 6.3b deleted `SettingsWindowController`, `SettingsPaneAdapter`, the `settingsHostStyle` value and every `.legacyWindow` branch, and the unused catalog keys. Every pane draws only its main-window body.
- 6.3c updated `docs/qa.md`, `AGENTS.md`, `BACKWARD_COMPATIBILITY.md` and the `.uxproof/` paths, and added the window budgets to `docs/perf.md` as "to be measured".
- Because the three commits are the last of the branch, the owner can cut them before the merge to keep the old Settings window for another release. A revert of them restores the old window with no data change.

## Rollback

The contract and plugin are additive; a revert of the PR stack restores today's behaviour. `notes.sqlite` stays on disk unread (export first). Source stores are not changed by this feature.

### Addendum: Notes workspace Phase 0 spike (2026-11-06)

Spec `.ai/specs/2026-11-04-notes-workspace.md`, Phase 0. The spike code is throwaway and is not in the repository; this addendum records what it showed. Three results follow, one per step: 0.1 editor (this section), 0.2 Markdown (next section) and 0.3 attribution (last section).

#### 0.1 Editor spike: GO (TextKit 2 `NSTextView`)

**Setup.** A scratch SwiftPM package outside the tree (release build, Swift 6.4.2, macOS 27.0.1, Apple M4 Max, 128 GB, dark appearance). One `NSTextView(usingTextLayoutManager: true)` in an `NSScrollView` in an `NSWindow` ordered back at 760 x 900 pt (the process is a headless command-line tool with activation policy `.prohibited`). Document: generated Markdown of headings, paragraphs with bold, italic and code, task-style list items and a three-column table per section, parsed by Foundation `AttributedString(markdown:)` with `.full` syntax and converted to an `NSAttributedString` (fonts from `inlinePresentationIntent`, headings from `PresentationIntent`, list indent, table cells as tab-separated rows with tab stops). The rendered text is **50 054 characters** in 1 417 blocks (source 62 094 characters, of which 1 593 table cell runs).

**What was built and checked.**

| Requirement | Result |
|---|---|
| TextKit 2 active (no TextKit 1 fallback) | yes, `textLayoutManager` non-nil for the whole run; `writingToolsBehavior = .none` accepted |
| Foundation-parsed Markdown incl. a table | headings, emphasis, code, list items and tables render. A table is tab-aligned rows with a bold header row. `NSTextTable` does not exist in TextKit 2, so there are no cell borders, no per-cell wrapping and no column alignment from the `:---:` markers unless a custom layout fragment draws them (not built). |
| Per-block gutter | a custom `NSTextLayoutFragment` (via `NSTextLayoutManagerDelegate`) draws a dot in the leading gutter outside the text container; confirmed on a `cacheDisplay` bitmap (about 840 blue pixels, one dot per fragment in view) and a screenshot. One fragment is one text element (paragraph, list item, table row); the production gutter must map fragments to `BlockAttribution` blocks. |
| Comment highlights | `setRenderingAttributes` on 20 ranges does not touch the text storage, redraw measured 0.3 to 0.4 ms; confirmed on the bitmap. The highlight follows edits because it is anchored by `NSTextRange` locations (production still stores offsets and re-anchors, spec Edge Cases). |
| Selection popover | the selection's rect comes from `enumerateTextSegments` (a plausible anchor, 17 pt tall, in text container coordinates); an `NSPopover` with a content controller was created. **Not shown**: a popover needs a visible, key window. |

**Typing latency at 50 054 rendered characters** (per keystroke: `insertText` at the insertion point, then `layoutViewport()` and `displayIfNeeded()`, 300 keystrokes each, release build, two identical runs agreed within 0.2 ms):

| Where | median | p95 | p99 | max |
|---|---|---|---|---|
| middle of the document | 0.95 ms | 1.24 ms | 1.51 ms | 1.58 ms |
| start | 1.13 ms | 1.46 ms | 1.59 ms | 1.69 ms |
| end | 0.72 ms | 0.93 ms | 1.12 ms | 1.40 ms |
| middle, plus a restyle of the edited paragraph's attributes | 1.25 ms | 1.66 ms | 1.92 ms | 2.44 ms |

Other numbers: set the whole 50 054-character attributed string and lay out the first viewport 14.5 to 19.6 ms (136 fragments created, the rest is laid out lazily, 3 179 fragments after all runs); parse and convert the whole document 43 ms (28 to 43 ms across runs). The last number is the budget that matters: **a whole-document re-parse on every keystroke would cost 28 to 43 ms**, so Phase 4 must re-render only the edited block(s) (split with `MarkdownBlocks.split`, re-parse the changed block, debounced) and keep the full parse for open and for Restore.

**Decision: GO.** TextKit 2 is fast enough by a wide margin at the spec's size: typing stays about 1 ms per keystroke in the measured path (a 16.7 ms frame budget at 60 Hz is not approached; the spec states no number, this addendum proposes **p99 under 8 ms at 50 000 characters** as the Phase 4 budget for `docs/perf.md`). Gutter dots and comment highlights work with public API only. The fallback in R-B1 (monospaced source editor with a preview tab) is not needed.

**Limits and open items the owner should know.**

- **Tables are the weak part.** Without `NSTextTable` the editor shows tables as tab-aligned text. Good enough for read and edit; borders, wrapped cells and alignment need a custom layout fragment (a bounded piece of Phase 4 work) or can ship later. Editing a table is editing its Markdown rows, as in any Markdown source editor.
- **Task lists are not parsed by Foundation** (see 0.2): `- [ ]` is a plain list item. The editor draws no checkboxes unless Notes post-processes the marker itself.
- **Not measured, because it cannot be done headlessly:** the real key event path (`NSEvent` to input context to `insertText`, key repeat, input methods and dead keys for Polish, marked text), frame latency through the compositor (`displayIfNeeded` on an offscreen, occluded window may not include GPU presentation), memory and layout cost while scrolling quickly through the whole document, VoiceOver, undo/redo grouping, live popover presentation and its focus behaviour, light appearance, and any other hardware (only an M4 Max was available; an M1-class Mac will be slower). Step 4.1 must repeat the typing measurement on the real editor in a real window and record it in `docs/perf.md`.
- The spike converted attributes itself; the production renderer must also ignore `link`, `imageURL` and any inline HTML run (display text only, never load or open anything, see 0.2).
