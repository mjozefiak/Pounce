# Plan — notes-workspace

**Source spec:** `.ai/specs/2026-11-04-notes-workspace.md` (spec B). Branch `feat/notes-workspace`, base `main`.

## Tasks

> Authoritative status table. `Status` is one of `todo` or `done`. On landing a Step, flip `Status` to `done` and fill the `Commit` column with the short SHA. The first row whose `Status` is not `done` is the resume point for `om-auto-continue-pr-loop`. Step ids and `Exec` cells are immutable once the plan is committed — per-Step commits touch only `Status` and `Commit`.

| Phase | Step | Title | Exec | Status | Commit |
|-------|------|-------|------|--------|--------|
| 0 | 0.1 | Editor spike (TextKit 2) and ADR 0008 addendum with measurements | inline | done | 1d1c964 |
| 0 | 0.2 | Verify AttributedString(markdown:) subset and Meetings export round-trip | inline | done | c5cb0c3 |
| 0 | 0.3 | Prototype BlockAttribution on revision fixtures (gate: all pass) | inline | done | d95aae3 |
| 1 | 1.1 | LintelKit note contract (NoteSource, NoteKey, PasteboardWriteOptions) with defaults | dispatch:capable | done | d11e37e |
| 1 | 1.2 | NotesPlugin and NotesPluginTests targets, DEBUG-only registration, --qa-notes | dispatch | done | 6602edf |
| 1 | 1.3 | LintelCore MarkdownBlocks.split | dispatch:cheap | done | 563521d |
| 1 | 1.4 | LintelCore MarkdownText (cleaned moves from MarkdownExporter, strippingBidiAndControls) | dispatch:cheap | done | 317b0e7 |
| 1 | 1.3-review-fix | MarkdownBlocks: backtick info strings, fences inside list items | inline | done | 14d69ee |
| 1 | 1.1-review-fix | PasteboardClient test: empty options replace | inline | done | 5ab5eec |
| 2 | 2.1 | MeetingNoteSource in MeetingsPlugin | dispatch:capable | done | a59bbfb |
| 2 | 2.2 | DictationNoteSource in DictationPlugin | dispatch | done | a5cc47a |
| 2 | 2.3 | openNote wiring without changing the current Cmd+O | dispatch | done | 863378c |
| 2 | 2.1-review-fix | DictationNoteSource.delete throws when the history closed | inline | done | c8ab03a |
| 2 | 2.2-review-fix | NoteSource.exists skips foreign or malformed keys per key | inline | done | db415df |
| 2 | 2.3-review-fix | MeetingWindowModel keeps its earlier edit behaviour | inline | done | 72487e7 |
| 2 | 2.4-review-fix | Comments on stream end versus reads corrected | inline | done | 68f9a36 |
| 3 | 3.1 | NoteLibrary aggregator | dispatch:capable | done | 267ec06 |
| 3 | 3.2 | Explorer, tab bar, path bar, status bar, NotesSection (DEBUG only) | dispatch:capable | done | 428211a |
| 3 | 3.3 | Read-only document views, Copy Markdown, Save .md | dispatch:capable | done | c369886 |
| 3 | 3.4 | Search across sources | dispatch | done | 7996a51 |
| 3 | 3.5 | Notes states and screenshot set | dispatch | done | ae378e7 |
| 3 | 3.3-review-fix | Export sanitises body and speaker names (M1) | inline | done | 8686172 |
| 3 | 3.2-review-fix | Content read budget and epochs, stale page dropped, one save panel (M2, M3) | inline | done | 3b29f61 |
| 3 | 3.2-review-fix | Explorer sentinel keyed on the page token (M4) | inline | done | 642958c |
| 3 | 3.2-review-fix | No force unwrap, ensureSources, save-error announcement, identical source set, stale comment (M5, lows) | inline | done | 6d98fa1 |
| 3 | 3.x-review-fix | Deterministic test waits and tests for the fixes | inline | done | 6b9fa52 |
| 4 | 4.0 | Store: NotesKeyStore, NotesLibraryOpener, v1-notes migration, NotesSettings, eraseData | dispatch:capable | done | 2357f9b |
| 4 | 4.0-review-fix | Store review: readOnly keeps delete and detach, in-memory detach, opener purge and migrationFailed, json_valid, snippet folding | inline | done | f362b8c, e88ccea, ea0ffb5, ddfb91a, 61cef1f |
| 4 | 4.1 | NoteEditor per Phase 0 decision, format bar, pasteboard markers | dispatch:capable | done | 74d7ce3 |
| 4 | 4.2 | RevisionWriter, OverlaySeeder, SourceReconciler | dispatch:capable | done | e53dcc6 |
| 4 | 4.3 | BlockAttribution gutter, legend, Details toggle | dispatch | done | 8808486 |
| 4 | 4.4 | Manual notes (Cmd+N, notes:<uuid>, title editing) | dispatch | done | 3299d7f |
| 4 | 4.2-review-fix (M3 proposed human kept) | review fix | inline | done | e0d479f |
| 4 | 4.2-review-fix (H1 H2 M4-M8, Lows) | review fix: durable release, retired text, max-wait, retry, conflict, stale seed, registry races | inline | done | afadff3 |
| 4 | 4.2-review-fix (M9 TSan NotesPluginTests) | review fix | inline | done | 8c8116d |
| 4 | 4.5 | History pane, Compare, Restore | dispatch | done | e73ba6a |
| 4 | 4.6 | Delete with confirmation sheets and kept-copies option | dispatch | done | 0401065 |
| 4 | 4.7 | Notes settings pane, retention rules, Export All, Erase | dispatch | done | 35ac222 |
| 4 | 4.6-review-fix | Review fix: kept-copy contract in BACKWARD_COMPATIBILITY (H1) | inline | done | 6299fbe |
| 4 | 4.6-review-fix | Review fix: discard typed text only after the delete (M1) | inline | done | fc51978 |
| 4 | 4.6-review-fix | Review fix: counting never resets the library (M2) | inline | done | a82c09c |
| 4 | 4.6-review-fix | Review fix: removal false when the owner cannot answer (M3) | inline | done | 02524e8 |
| 4 | 4.5-review-fix | Review fix: restore target guard and reasons (Low) | inline | done | 33cfd93 |
| 4 | 4.x-review-fix | Review fix: ADR 0008 deviations addendum, chip test (M4) | inline | done | c0f4a6a, 2c5b844 |
| 5 | 5.1 | note_comment store, anchors, re-anchoring | dispatch | done | 250572a |
| 5 | 5.2 | Comment popover, inspector Comments pane, highlights | dispatch | done | d965d70 |
| 5 | 5.3 | Revise-with-N-comments counts and accessibility | dispatch | done | d965d70 (same commit as 5.2) |
| 5 | 5.2-review-fix | Review fixes: comment length limit, selection cap, Escape, anchor revision check, card contrast | inline | done | 2b2c9e2, 7e4d3c2, 656fc5c |
| 5 | 5.3-review-fix | Review fixes: anchor trust rule, grapheme-safe search, cached resolution, stale reads, Revise count | inline | done | e413e9b |
| 6 | 6.1 | ReviseNotesPrompt and ReviseGuard | dispatch | done | a900769 |
| 6 | 6.2 | ReviseService, EditLock state machine through LLMLease | dispatch:capable | done | 4dda303 |
| 6 | 6.3 | Proposed revisions: Compare with Apply/Discard | dispatch | todo | — |
| 6 | 6.4 | Revise regression corpus, RealReviseTests, perf budgets | dispatch | todo | — |
| 7 | 7.4 | Docs: AGENTS.md, BACKWARD_COMPATIBILITY.md, qa.md, perf.md, localization check | inline | todo | — |
| 7 | 7.1 | ENABLES NOTES FOR USERS: palette, Hide content, remove DEBUG guards | inline | todo | — |
| 7 | 7.2 | ENABLES NOTES FOR USERS: Welcome mentions Notes | dispatch | todo | — |
| 7 | 7.3 | ENABLES NOTES FOR USERS: remove Meetings window after parity checklist | inline | todo | — |

## Goal

Implement the Notes workspace (NotesPlugin, editor, comments, history, agent revisions) exactly as the spec's Implementation Plan describes, hidden from users until the final commits.

## Scope and owner decisions

- One PR, one commit per Step (owner, 2026-11-06). Spec step bodies are the acceptance criteria; read the step text in the spec, do not paraphrase from this table.
- **Ordering deviation:** the spec lists 7.1–7.4; here 7.4 (docs) runs first and **7.1, 7.2, 7.3 are the last three commits**, each titled "ENABLES NOTES FOR USERS", so the owner can cut them. Merging them enables Notes for users.
- Until 7.1, `NotesPlugin` is registered only `#if DEBUG`; no Keychain item, `notes.sqlite`, `plugins.notes.*` key or panel reaches users. No store code before 4.0.
- Phase 0 is a spike with go/no-go; a fallback or no-go result stops the run for an owner decision.

## Non-goals

Spec A behaviour, new dependencies, runtime-loaded plugins, anything the spec's "Not doing" lists.

## Risks

Editor (TextKit 2) performance, migrations, agent revisions unverified in isolation; risk-high; flaky time-dependent tests (use injected clocks).

## Binding rules (every Step)

Worktree only; no stash, no amend or force-push of pushed commits; never add `qa-approved` / `merge-queue`. LintelKit changes additive with defaults; plugins never import each other or LintelApp (Meetings/Dictation only through `NoteSource`); colours via LintelBrand; every Localizable key has en and pl, PL never inflects "Lintel"; settings keys in BACKWARD_COMPATIBILITY.md §3, contract fields §1; "Pounce" only on `LEGACY-POUNCE` lines; never log note, transcript or dictation text; no `fatalError`/`try!`/force unwrap in plugin production code; Swift Testing, no real windows/HUD/mic/Keychain/UserDefaults, deterministic tests. Stop and ask the owner on: new dependency, protected surface change beyond the spec, spec contradicting main, test failing after 2 fix attempts, anything deleting user data.

## Implementation Plan

- **0.1** Editor spike (TextKit 2) and ADR 0008 addendum with measurements
- **0.2** Verify AttributedString(markdown:) subset and Meetings export round-trip
- **0.3** Prototype BlockAttribution on revision fixtures (gate: all pass)
- **1.1** LintelKit note contract (NoteSource, NoteKey, PasteboardWriteOptions) with defaults
- **1.2** NotesPlugin and NotesPluginTests targets, DEBUG-only registration, --qa-notes
- **1.3** LintelCore MarkdownBlocks.split
- **1.4** LintelCore MarkdownText (cleaned moves from MarkdownExporter, strippingBidiAndControls)
- **2.1** MeetingNoteSource in MeetingsPlugin
- **2.2** DictationNoteSource in DictationPlugin
- **2.3** openNote wiring without changing the current Cmd+O
- **3.1** NoteLibrary aggregator
- **3.2** Explorer, tab bar, path bar, status bar, NotesSection (DEBUG only)
- **3.3** Read-only document views, Copy Markdown, Save .md
- **3.4** Search across sources
- **3.5** Notes states and screenshot set
- **4.0** Store: NotesKeyStore, NotesLibraryOpener, v1-notes migration, NotesSettings, eraseData
- **4.1** NoteEditor per Phase 0 decision, format bar, pasteboard markers
- **4.2** RevisionWriter, OverlaySeeder, SourceReconciler
- **4.3** BlockAttribution gutter, legend, Details toggle
- **4.4** Manual notes (Cmd+N, notes:<uuid>, title editing)
- **4.5** History pane, Compare, Restore
- **4.6** Delete with confirmation sheets and kept-copies option
- **4.7** Notes settings pane, retention rules, Export All, Erase
- **5.1** note_comment store, anchors, re-anchoring
- **5.2** Comment popover, inspector Comments pane, highlights
- **5.3** Revise-with-N-comments counts and accessibility
- **6.1** ReviseNotesPrompt and ReviseGuard
- **6.2** ReviseService, EditLock state machine through LLMLease
- **6.3** Proposed revisions: Compare with Apply/Discard
- **6.4** Revise regression corpus, RealReviseTests, perf budgets
- **7.4** Docs: AGENTS.md, BACKWARD_COMPATIBILITY.md, qa.md, perf.md, localization check
- **7.1** ENABLES NOTES FOR USERS: palette, Hide content, remove DEBUG guards
- **7.2** ENABLES NOTES FOR USERS: Welcome mentions Notes
- **7.3** ENABLES NOTES FOR USERS: remove Meetings window after parity checklist
