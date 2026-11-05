# Lintel main window and redesigned Settings (spec A) — execution plan

Run: `2026-11-05-lintel-main-window` · Branch: `feat/lintel-main-window` · Mode: Spec-implementation run (om-auto-create-pr-loop)
Source spec: `.ai/specs/2026-11-04-lintel-main-window.md` · ADR: `docs/decisions/0008-main-window-and-notes-library.md` · Prototype: `.ai/prototypes/lintel-app/index.html`

## Tasks

> Authoritative status table. `Status` is one of `todo` or `done`. On landing a Step, flip `Status` to `done` and fill the `Commit` column with the short SHA. The first row whose `Status` is not `done` is the resume point for `om-auto-continue-pr-loop`. Step ids and `Exec` cells are immutable once the plan is committed — per-Step commits touch only `Status` and `Commit`.

| Phase | Step | Title | Exec | Status | Commit |
|-------|------|-------|------|--------|--------|
| 0 | 0.1 | Add .uxproof/ to git (stale copy first, refresh second) | dispatch:standard | done | 672d8e3 |
| 0 | 0.2 | Apply the deviation tables to the prototype | dispatch:cheap | done | 10a3b03 |
| 1 | 1.1 | LintelKit contract additions, canBeDisabled, inactive panes | dispatch:capable | done | 01abb12 |
| 1 | 1.2 | MainWindowController, window state keys, QA argument | dispatch:capable | done | 71edbcc |
| 1 | 1.3 | Host the existing Settings panes in the window (adapter) | dispatch:standard | done | d9b39ef |
| 1 | 1.4 | MainMenuController and MainMenuPolicy | dispatch:standard | done | 72a68da |
| 1 | 1.5 | Dock, status item, Cmd-comma and openModels routing behind the gate | dispatch:capable | done | f4b5831 |
| 1 | 1.6 | LintelUI target, moved brand and TextSize, host style values | dispatch:capable | done | 6f36f7a |
| 1 | 1.5-review-fix | Review fix: Dock click counts only real windows (H1) | dispatch:standard | done | 8233eb5 |
| 1 | 1.2-review-fix | Review fix: call willHide on every mode switch, close and quit path (M1) | dispatch:standard | done | 3db70df |
| 1 | 1.1-review-fix | Review fix: inactive-pane test runs pane lifecycle in a real window; no work while inactive (M2) | dispatch:standard | done | 8576bc0 |
| 1 | 1.6-review-fix | Review fix: meeting window text size, AGENTS.md Window/ row, adapter sidebar and close-task nits (L2, L3, L4, L6) | dispatch:standard | done | cc3132b |
| 2 | 2.1 | SettingsSidebar and SettingsSidebarModel | dispatch:standard | done | a4bdff3 |
| 2 | 2.2 | StatusBanner and StatusDerivation | dispatch:capable | done | 4d9a82a |
| 2 | 2.3 | SettingsPane template, ConfirmSheet, footer helper, scanning tests | dispatch:standard | done | 423ea82 |
| 2 | 2.4 | SettingsKeys ownership and per-plugin key coverage tests | dispatch:standard | done | ca8ff98 |
| 2 | 2.2-review-fix | Review fix: sidebar dot from derivation, live sidebar after state change, ok banner when nothing is wrong, error dot colour | dispatch:capable | done | 644a84f |
| 2 | 2.3-review-fix | Review fix: legacy-branch scanner else/!= handling, colour rule gaps, ConfirmSheet shortcuts, neutral glyph contrast | dispatch:standard | done | 94dc7e2 |
| 3 | 3.1 | PermissionRow and PermissionsPane | dispatch:standard | done | 99a48b4 |
| 3 | 3.2 | ModelsPane, ModelRow, ModelsPaneModel, ModelUsage declarations | dispatch:capable | done | d289bd2 |
| 3 | 3.3 | Remove duplicated microphone rows and model cards (mainWindow only) | dispatch:capable | done | 016f6fc |
| 3 | 3.4 | Confirmation sheets for Clear and Erase | dispatch:standard | done | 472d414 |
| 3 | 3.4-review-fix | Review fix: ConfirmSheet runs onConfirm before closing | dispatch:standard | done | 8ba35b5 |
| 3 | 3.2-review-fix | Review fix: confirm model removal, custom-folder models are not "needed", loaded flag, refresh generation, in-use parity tests | dispatch:capable | done | 287d17b |
| 3 | 3.2-qa-fix | QA fix: Permissions states in the new window, Choose Folder style, text size on Models rows | dispatch:standard | done | 5ece8fc |
| 3 | 3.2-fidelity-fix | Fidelity fix: Models pane matches the prototype set-models (sections, card rows, licence, primary action, footer, wording) | dispatch:standard | done | b022609 |
| 3 | 3.2-fidelity-fix-2 | Fidelity fix: banner width and accent action, no wrapped Download label, one Choose Folder style | dispatch:standard | done | bbfd7b7 |
| 3 | 3.2-fidelity-fix-3 | Fidelity fix: banner and pane body share one layout column | dispatch:standard | done | 88aee3f |
| 4 | 4.1 | General and Features panes onto the template | dispatch:standard | done | ec370f2 |
| 4 | 4.2 | Apps pane onto the template | dispatch:standard | done | c2e60bc |
| 4 | 4.3 | Files pane onto the template | dispatch:standard | done | e170580 |
| 4 | 4.4 | Clipboard pane onto the template | dispatch:standard | done | 42b5dec |
| 4 | 4.1-review-fix | Review fix: keyboard-reachable Result order, section-order move tests | dispatch:standard | done | 0a26e5a |
| 4 | 4.3-review-fix | Review fix: pure settingsStatus getters (no state change in view body), Full Disk Access acknowledged only after setup | dispatch:capable | done | 7468a2d |
| 4 | 4.4-review-fix | Review fix: one coalesced status signal per clipboard copy, plural and behavioural pane tests, nits | dispatch:standard | done | 0bafb18 |
| 5 | 5.1 | Dictation pane onto the template | dispatch:standard | done | 389bb65 |
| 5 | 5.2 | Meetings pane onto the template | dispatch:capable | done | 6c9f0b9 |
| 5 | 5.3 | Clear/Erase confirmation copy with kept-copies checkbox (L1-39) | dispatch:standard | done | c7d3a71 |
| 5 | 5.2-review-fix | Review fix: banner count includes denied required permissions, refresh the banner when the engine changes, pinned shell test | dispatch:standard | done | db6bcb5 |
| 6 | 6.1 | Welcome final page "You’re set" | dispatch:standard | done | cb945ef |
| 6 | 6.5a | Fidelity: shell chrome (sidebar, banner, off-state dimming, section headers, column, window chrome and size, sidebar dots) | dispatch:capable | done | d6bb077 |
| 6 | 6.5b | Fidelity: secondary and destructive button styles, ConfirmSheet confirm button | dispatch:standard | done | 5b8b0ad |
| 6 | 6.5c | Fidelity: Permissions pane rows | dispatch:standard | done | 8783412 |
| 6 | 6.5d | Fidelity: Advanced pane on the template (Show Again, About) | dispatch:standard | done | 8c3d8be |
| 6 | 6.5e | Fidelity: Models rows, Download icon, banner copy | dispatch:standard | done | 900eb16 |
| 6 | 6.5f | Fidelity: Polish copy | dispatch:standard | done | 26c06a6 |
| 6 | 6.5g | Fidelity: Welcome layout and the onboarding QA argument | dispatch:capable | done | 7a546ce |
| 6 | 6.5h | Fidelity: Welcome final label, picker tint, Models Remove, Permissions rows, ConfirmSheet layout | dispatch:standard | done | 3c9b460 |
| 6 | 6.5i | Release parity: restore the release wording of shared catalog keys changed for the new window | dispatch:standard | done | dad5d1f |
| 6 | 6.5 | Final 1:1 re-comparison of every screen with the prototype and remaining-differences list | inline | done | 6.5a–i |
| 6 | 6.4 | docs(spec): correct the Phasing sentence about phases and PRs | inline | done | 3b684f6 |
| 6 | 6.3a | Remove the DEBUG gate (window enabled for users) | dispatch:capable | done | 9fce98e |
| 6 | 6.3b | Delete SettingsWindowController, the adapter and .legacyWindow branches | dispatch:capable | done | cbd3376 |
| 6 | 6.3c | Update docs/qa.md, AGENTS.md rows, BACKWARD_COMPATIBILITY.md, catalog check | dispatch:standard | done | 5cfd00f |
| 6 | 6.3c-fix-a | Review fix (after the gate commits): Use Downloaded Model reachable in Models, Try it on an example reachable | dispatch:standard | done | 7580666 |
| 6 | 6.3c-fix-b | Review fix: ReleaseGateTests assert the needles exist, AGENTS.md package row | dispatch:standard | done | 8cdf2c9 |
| 6 | 6.3c-fix-c | Test fix: no test may show a real recording HUD or hang | dispatch:capable | done | 0ac3d53 |
| 6 | 6.6a | Owner fix: the prototype's warm neutral palette (LintelBrand window, sidebar, card, secondary text, hairline, fill, window tint) in the main window, Settings, welcome and plugin panes | dispatch | done | d1d0795 |
| 6 | 6.6b | Owner decision: `PluginManifest.summary`, the one-line feature descriptions of prototype `set-features` in Settings → Features | dispatch | done | f69b09d |
| 6 | 6.6c | Owner decision: `ModelUsage.customFolder`; the Models pane shows the state of a folder Dictation or Meetings chose instead of "Not downloaded" | dispatch | done | b66a4e6 |
| 6 | 6.6d | Owner decision: Settings names of the prototype (Apps, Clipboard); `PluginManifest.sectionTitle` keeps the launcher headings (Applications, Clipboard History) | dispatch | done | f16bd10 |
| 6 | 6.6e | Owner decision: Polish copy never declines "Lintel" (nominative only, e.g. "w aplikacji Lintel"); PolishCopyTests guard | dispatch | done | 851d2e8 |
| 6 | 6.6f | Welcome plugin pages on the prototype's single column: `OnboardingStep.text`, `WelcomeStepLayout` + step parts in LintelUI, Files/Clipboard/Dictation/Meetings steps on it (Apps has no step) | dispatch | done | 286df4d |
| 6 | 6.7a | Final 1:1 pass: the pane title and the banner title in `LintelBrand.ink` (were the system label grey) | inline | done | 688a5a1 |
| 6 | 6.7b | Final 1:1 pass: banner glyphs of the prototype (`warn` triangle for attention and error, ringed `info`), semibold | inline | done | f066176 |
| 6 | 6.7c | Final 1:1 pass: Features uses the prototype's grid symbol in the sidebar; Features rows put the symbol in front of the name | inline | done | 4b74e41 |
| 6 | 6.7d | Final 1:1 pass: Permissions rows (Full Disk Access optional: "Not granted", secondary button, after the allowed rows, "· optional"; "Not asked yet" in the attention colour; "System audio recording"; the prototype's footer) | inline | done | 1e18198 |
| 6 | 6.7e | Final 1:1 pass: the Advanced card starts where the other panes' banner does (16 pt higher) | inline | done | (this commit) |

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

Deviation from the spec (3.2-review-fix): the speech `ModelUsage` is `isRequired: speechModelFolder == nil` instead of always `true`, because `ModelUsage` carries no folder (contract unchanged) and the Models pane would otherwise call a model in a chosen folder "Not installed · Needed"; such a row still reads "Not installed".

## External References

None (`--skill-url` not used).
