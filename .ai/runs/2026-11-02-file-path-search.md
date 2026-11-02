# Execution plan: file search by path (path mode)

Source doc: .ai/specs/2026-11-02-file-path-search.md (spec PR #11)

## Goal
A launcher query that starts with `/` or `~` lists that folder straight from disk (the folder row, then its contents, filtered by the text after the last `/`), so pasted paths through hidden or excluded folders work.

## Scope
- `Sources/FilesPlugin/`: new `PathQuery`, `TCCProtectedLocations`, `DirectoryLister`, `PathSearchSource`; `FileSearchSource` stays silent for path queries; `FileActions.recordsQueryPrefix`; one-directory reader extracted from `BulkScanner`.
- `Tests/FilesPluginTests/`: unit tests for every new type.
- `Resources/Localizable.xcstrings`, `docs/perf.md`, `docs/qa.md`, `AGENTS.md`.

## Non-goals
- Tab/⇧Tab completion, `PounceKit` contract changes (spec A6).
- Path fragments in the index, hidden items by default (A1).
- Changes to the index, snapshot, settings keys or "Recently Used".

## Implementation Plan

### Phase 1: Path mode
1.1 `PathQuery`: trim raw, trigger (A2), folder/filter split, `~` expansion, quotes and `\ ` unescaping; tests.
1.2 `TCCProtectedLocations`: protected list (A5) and `requiresFullDiskAccess`; tests.
1.3 `DirectoryLister` on a one-directory reader shared with `BulkScanner` (states, 20 000 cap, last-folder cache, cancellation); tests.
1.4 `PathSearchSource`, silent `FileSearchSource`, `FileActions.recordsQueryPrefix`, registration; tests including ordering through the real `Ranker`.
1.5 Strings, `docs/perf.md`, `docs/qa.md`, `AGENTS.md`; QA in the debug app.

## Risks
- A TCC prompt from an unlisted protected location: guarded by the list plus manual QA.
- Extracting the reader from `BulkScanner` could regress scanning: its tests and TSan must stay green.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Path mode

- [x] 1.1 PathQuery parser — e05b891
- [x] 1.2 TCCProtectedLocations — f7baf34
- [x] 1.3 DirectoryLister and shared one-directory reader — f5e65d3
- [x] 1.4 PathSearchSource and FileSearchSource changes — 0dc936f
- [ ] 1.5 Strings, docs and QA
