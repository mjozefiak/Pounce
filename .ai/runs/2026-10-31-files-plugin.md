# Execution plan: Phase 3 file search (Pounce MVP)

Source doc: .ai/specs/2026-10-31-pounce-launcher-mvp.md
Branch: feat/files-plugin (base: feat/clipboard-plugin, stacked on #6, which is stacked on #4 and #3)

## Goal

Ship Phase 3 of the MVP spec (v0.3): filename search over Pounce's own in-memory index of `~` and
`/Applications`, kept fresh with FSEvents and persisted as a snapshot, with the Full Disk Access
onboarding shown before the first scan, settings for roots and exclusions, and the user-defined
order of result sections (issue #5) now that there are two search sections.

## Scope

- `FilesPlugin` target and `FilesPluginTests`, registered with one line in `PluginRegistry`:
  - `RootPlanner` (spec step 3.0): roots and protected folders with and without Full Disk Access.
    Without it, `~/Desktop`, `~/Documents`, `~/Downloads` and iCloud Drive are skipped unless the
    user adds them one at a time; iCloud Drive (`~/Library/Mobile Documents`) is its own root.
  - Full Disk Access onboarding step (`files.fullDiskAccess`), shown before the first scan; the scan
    starts once the step is finished or skipped.
  - `IgnoreRules` and `BulkScanner` (`getattrlistbulk`, parallel workers, packages indexed as one
    item, other volumes and firmlinks skipped, symlinks never followed) (step 3.1).
  - `NameStore` owned by `actor FileIndex`, publishing immutable snapshots; parallel top-N search
    with cancellation and a `boost` (depth penalty, recent mtime) (step 3.2).
  - `FileSearchSource` and file actions: Return opens, ⌘Return reveals in Finder, ⌘C copies the path,
    ⌘⇧C copies the file; uses recorded through `UsageRecorder` with `files:<path>` keys (step 3.3).
  - `FileEventWatcher` (FSEvents, file events, coalesced per directory; `MustScanSubDirs`,
    `RootChanged`, dropped events and wrapped ids trigger rescans) (step 3.4).
  - `IndexSnapshot` in `Plugins/files/index.snapshot`: versioned, LZFSE-compressed, atomic writes after
    the scan, every 100 000 entries during the first scan and every 10 minutes; loaded at launch with
    catch-up from `last_event_id` after a device-UUID check (step 3.5).
  - Files settings pane (roots, exclusions, protected folders including iCloud Drive), indexing
    progress and the no-Full-Disk-Access banner in the panel, `eraseData` (step 3.6).
- `PounceKit` additions, additive only with defaults (R8): a search-mode status contribution
  (`PouncePlugin.searchStatus`) so a plugin can show progress or a banner above its results.
- `PounceApp`: Full Disk Access detection in `SystemPermissionsReader` (reads a protected path, never
  prompts), status rows in the panel, user section order in Settings → Features (`app.sectionOrder`,
  issue #5), QA flags (`--qa-full-disk-access`, fixture roots).
- Docs: `docs/qa.md`, `docs/perf.md` (index memory per entry on a fixture tree), `AGENTS.md`,
  `BACKWARD_COMPATIBILITY.md` (new settings keys, snapshot format); `en` + `pl` strings; CI runs the
  `FileIndex` and `FilesPlugin` tests under Thread Sanitizer.

## Non-goals

- Content search, external volumes (out of MVP scope).
- Permissions and Advanced panes, the welcome screen, the full accessibility audit (Phase 4).
- Measuring on the owner's real home folder: this run measures a synthetic fixture tree only.
- The `om-auto-review-pr` loop (a separate reviewer runs it).

## Implementation Plan

### Phase 1: Plugin target and Full Disk Access gate

1.1 `FilesPlugin` target, registry line, settings, `RootPlanner` (spec 3.0). Test: root selection with
and without Full Disk Access.
1.2 Full Disk Access probe in the shell, onboarding step before the first scan, QA flag. Test: probe on
fixture paths, scan waits for the step.

### Phase 2: Scanner and index

2.1 `IgnoreRules` + `BulkScanner` (spec 3.1). Test: fixture tree with a package, a symlink and
`node_modules` gives the expected list.
2.2 `NameStore`, `actor FileIndex`, snapshot publication, parallel top-N search (spec 3.2). Test: top-N
correctness, concurrent updates during searches under TSan, cancellation, smoke benchmark.

### Phase 3: Search, watcher and snapshot

3.1 `FileSearchSource` and file actions (spec 3.3). Test: actions on temporary files.
3.2 `FileEventWatcher` and rescan planning (spec 3.4). Test: create, rename and delete show up in
results within 2 s.
3.3 `IndexSnapshot` persistence and catch-up (spec 3.5). Test: restart with a changed file gives fresh
results without a full scan; other UUID, `complete = false` or a damaged file force a full scan.

### Phase 4: Settings, status and section order

4.1 Search status contribution: indexing progress and the no-Full-Disk-Access banner (spec 3.6).
4.2 Files settings pane: roots, exclusions, protected folders (spec 3.6). Test: `IgnoreRules` from
settings.
4.3 User-defined section order (issue #5).
4.4 Strings, accessibility, docs (`docs/perf.md` memory measurement, `docs/qa.md`, `AGENTS.md`,
`BACKWARD_COMPATIBILITY.md`), CI Thread Sanitizer step.

### Phase 5: Verification

5.1 Full validation gate and Thread Sanitizer run.
5.2 Native QA on fixture data (light/dark, en/pl) with evidence on the PR.

## Risks

- `getattrlistbulk` parsing is manual pointer work: covered by fixture tests (packages, symlinks,
  hidden files, unreadable directories).
- FSEvents timing on CI runners: the integration test uses a generous timeout; the 2 s target is
  checked locally.
- Memory per entry (R6): measured on a synthetic tree; the real-home budget (< 150 MB) is a manual
  item for the owner.
- Full Disk Access cannot be granted in CI or QA: the probe is unit-tested on fixture paths, the real
  grant is a manual QA item.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Plugin target and Full Disk Access gate

- [x] 1.1 FilesPlugin target, registry line, settings and RootPlanner — b1a2a0d
- [x] 1.2 Full Disk Access probe, onboarding step before the first scan, QA flag — b1a2a0d, 1b2093c

### Phase 2: Scanner and index

- [x] 2.1 IgnoreRules and BulkScanner — b1a2a0d
- [x] 2.2 NameStore, FileIndex actor and parallel top-N search — b1a2a0d

### Phase 3: Search, watcher and snapshot

- [x] 3.1 FileSearchSource and file actions — b1a2a0d
- [x] 3.2 FileEventWatcher and rescan planning — b1a2a0d
- [x] 3.3 IndexSnapshot persistence and catch-up — b1a2a0d

### Phase 4: Settings, status and section order

- [x] 4.1 Search status: indexing progress and no-Full-Disk-Access banner — 90347ae, 5025497
- [x] 4.2 Files settings pane: roots, exclusions, protected folders — b1a2a0d
- [x] 4.3 User-defined section order (issue #5) — 5025497
- [x] 4.4 Strings, accessibility, docs and CI Thread Sanitizer step — cf1e7d2

### Phase 5: Verification

- [x] 5.1 Full validation gate and Thread Sanitizer run — cf1e7d2
- [ ] 5.2 Native QA on fixture data with evidence on the PR
