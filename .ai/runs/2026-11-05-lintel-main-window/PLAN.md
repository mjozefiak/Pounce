# Lintel main window and redesigned Settings (spec A) — execution plan

Run: `2026-11-05-lintel-main-window` · Branch: `feat/lintel-main-window` · Mode: Spec-implementation run (om-auto-create-pr-loop)
Source spec: `.ai/specs/2026-11-04-lintel-main-window.md` · ADR: `docs/decisions/0008-main-window-and-notes-library.md` · Prototype: `.ai/prototypes/lintel-app/index.html`

## Tasks

> Authoritative status table. `Status` is one of `todo` or `done`. On landing a Step, flip `Status` to `done` and fill the `Commit` column with the short SHA. The first row whose `Status` is not `done` is the resume point for `om-auto-continue-pr-loop`. Step ids and `Exec` cells are immutable once the plan is committed — per-Step commits touch only `Status` and `Commit`.

| Phase | Step | Title | Exec | Status | Commit |
|-------|------|-------|------|--------|--------|
| 0 | 0.1 | Add .uxproof/ to git (stale copy first, refresh second) | dispatch:standard | done | 05a2276 |
| 0 | 0.2 | Apply the deviation tables to the prototype | dispatch:cheap | done | df95001 |
| 1 | 1.1 | LintelKit contract additions, canBeDisabled, inactive panes | dispatch:capable | todo | — |
| 1 | 1.2 | MainWindowController, window state keys, QA argument | dispatch:capable | todo | — |
| 1 | 1.3 | Host the existing Settings panes in the window (adapter) | dispatch:standard | todo | — |
| 1 | 1.4 | MainMenuController and MainMenuPolicy | dispatch:standard | todo | — |
| 1 | 1.5 | Dock, status item, Cmd-comma and openModels routing behind the gate | dispatch:capable | todo | — |
| 1 | 1.6 | LintelUI target, moved brand and TextSize, host style values | dispatch:capable | todo | — |
| 2 | 2.1 | SettingsSidebar and SettingsSidebarModel | dispatch:standard | todo | — |
| 2 | 2.2 | StatusBanner and StatusDerivation | dispatch:capable | todo | — |
| 2 | 2.3 | SettingsPane template, ConfirmSheet, footer helper, scanning tests | dispatch:standard | todo | — |
| 2 | 2.4 | SettingsKeys ownership and per-plugin key coverage tests | dispatch:standard | todo | — |
| 3 | 3.1 | PermissionRow and PermissionsPane | dispatch:standard | todo | — |
| 3 | 3.2 | ModelsPane, ModelRow, ModelsPaneModel, ModelUsage declarations | dispatch:capable | todo | — |
| 3 | 3.3 | Remove duplicated microphone rows and model cards (mainWindow only) | dispatch:capable | todo | — |
| 3 | 3.4 | Confirmation sheets for Clear and Erase | dispatch:standard | todo | — |
| 4 | 4.1 | General and Features panes onto the template | dispatch:standard | todo | — |
| 4 | 4.2 | Apps pane onto the template | dispatch:standard | todo | — |
| 4 | 4.3 | Files pane onto the template | dispatch:standard | todo | — |
| 4 | 4.4 | Clipboard pane onto the template | dispatch:standard | todo | — |
| 5 | 5.1 | Dictation pane onto the template | dispatch:standard | todo | — |
| 5 | 5.2 | Meetings pane onto the template | dispatch:capable | todo | — |
| 5 | 5.3 | Clear/Erase confirmation copy with kept-copies checkbox (L1-39) | dispatch:standard | todo | — |
| 6 | 6.1 | Welcome final page "You're set" | dispatch:standard | todo | — |
| 6 | 6.4 | docs(spec): correct the Phasing sentence about phases and PRs | inline | todo | — |
| 6 | 6.3a | Remove the DEBUG gate (window enabled for users) | dispatch:capable | todo | — |
| 6 | 6.3b | Delete SettingsWindowController, the adapter and .legacyWindow branches | dispatch:capable | todo | — |
| 6 | 6.3c | Update docs/qa.md, AGENTS.md rows, BACKWARD_COMPATIBILITY.md, catalog check | dispatch:standard | todo | — |

Step 6.2 (⌃X confirmation) is NOT in this table: it is a separate PR on a fresh branch from main, done after this PR is complete.

## Goal

Give Lintel a main window (Dock, menu bar item, ⌘, open it) with a redesigned Settings mode: grouped sidebar, one status banner per pane, one PermissionRow, one Models pane, one Permissions pane, plus the additive LintelKit contract and the new `LintelUI` target — all per spec A.

## Owner overrides (2026-11-05, supersede the spec's Phasing text)

- The whole of spec A is ONE PR on ONE branch, one commit per Step. The spec sentence "each phase ships on its own feat/ branch and PR" is overridden (corrected in Step 6.4).
- Step 6.2 is a separate PR (risk-high), depends on 1.1 only, made after this PR is complete.
- Step 6.3 is split into 6.3a–6.3c, the LAST commits, so the owner can cut them before merge. The PR body must say: "merging these commits enables the new window for users".
- Decisions L1-39 (kept copies checkbox) and `LintelUI` as its own target are in the specs. L1-40 concerns spec B only.

## Scope

Spec A, Phases 0–6 except 6.2. Non-goals: spec B (Notes workspace, NotesPlugin), 6.2, a section switcher, "Erase all Lintel data", in-app language switch, any new setting beyond the three window keys.

## Implementation Plan

Each Step is exactly the spec's Implementation Plan entry of the same number (`.ai/specs/2026-11-04-lintel-main-window.md`, section "Implementation Plan"), including its tests. Executors read the spec; this plan does not copy it. Additions:

- 6.4: edit the spec's Phasing paragraph ("Each phase ships on its own `feat/` branch and PR…") to state that spec A shipped as one PR with one commit per step, 6.2 as its own PR; docs-only.
- 6.3a: remove the `#if DEBUG` / `--qa-window`-only gating of window opening, Dock/⌘,/status-item/openModels/openNote routing (ADR 0008 "Release gate"); keep `--qa-window` as a launch argument if the spec's 6.3 text requires it for QA.
- 6.3b: delete `SettingsWindowController`, the adapter, `settingsHostStyle` and `.legacyWindow` branches; update tests that referenced them.
- 6.3c: `docs/qa.md` (`--qa-window`), AGENTS.md rows, BACKWARD_COMPATIBILITY.md §1/§3/§5 consistency, `Localizable.xcstrings` check, full gate + TSan.

### Phase-boundary protocol (after the last Step of every Phase, before the next Phase)

1. Full gate: `swift build`, `swift test`, `swift format lint --strict -r Sources Tests`; TSan (`swift test --sanitize=thread --filter PluginHostTests` and `FilesPluginTests`) when PluginHost/FilesPlugin changed. Known flaky, report only: `AppsPluginTests.theSeedWaitsForTheFirstFinishedScan`, "Index controller" timing tests in FilesPluginTests.
2. Self code review of the phase diff with `om-code-review` (CODE_REVIEW.md). Fix Critical/High/Medium as `X.Y-review-fix` Steps. Post the result as a short PR comment.
3. UI-visible phase: manual QA with `om-auto-qa-pr` (debug app via `CONFIGURATION=debug scripts/make-app.sh`, `--qa-…` args, light/dark, S and XL, EN and PL, per `docs/qa.md`). Check every screenshot for private data before upload (public repo). Contract/test-only phases: say so in the comment.
4. PR comment with the phase result and a "Not verified" list.

### Hard rules (every Step)

No merge, no force-push, no `git stash`, never add `qa-approved` or `merge-queue`; do not touch the untracked `Tests/MeetingsPluginTests/LibraryDiagnostics.swift` in the main checkout; LintelKit additive only with defaults for every new member; plugins never import `LintelApp` or each other; colours only via `LintelBrand`; no glass in Settings; every `Localizable.xcstrings` key has `en` and `pl`; new settings keys go to `BACKWARD_COMPATIBILITY.md` §3; old name "Pounce" only on `LEGACY-POUNCE` lines; never log note content; the new window, Dock/⌘, routing and anything changing release behaviour stay behind `#if DEBUG` / `--qa-window` until 6.3a.

### Stop conditions (ask the user, do not decide)

Spec contradicts code on main and cannot be done without a contract change; a test still fails after 2 fix attempts; a new dependency or a protected-surface change outside the spec is needed; anything would delete user data.

## Risks

R-A1 protected contract (additive only); R-A3 menu vs launcher focus; R-A4 pane regressions (key coverage tests); R-A5 package graph (new `LintelUI`, `LintelApp → LintelSpeech`); R-A7 release gate. Large PR: mitigated by one commit per Step and phase-boundary reviews.

## External References

None (`--skill-url` not used).
