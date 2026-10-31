# Execution plan: Phase 1 panel and app search (Pounce MVP)

Source doc: .ai/specs/2026-10-31-pounce-launcher-mvp.md
Branch: feat/apps-plugin (base: feat/scaffold, stacked on #3)

## Goal

Ship Phase 1 of the MVP spec (v0.1): a usable app launcher. A global shortcut opens a Liquid Glass panel,
typing finds applications with fzf-style matching and frecency ranking, Return opens the app, and a
Settings window (General, Features) lets the user change the shortcut, which defaults to ⌘Space or
⌃⌥Space when Spotlight holds ⌘Space (Q10).

## Scope

- `PounceCore`: `TextNormalizer`, `FuzzyMatcher` (tiers, fzf v2 style scoring, highlight ranges),
  `Ranker` (tiers, frecency with a 7-day half-life, query associations, source boost).
- `PouncePersistence`: `ranking.sqlite` migrator (`usage_stat`, `query_association`) and
  `UsageRepository` implementing `UsageRecorder`; the database is owned by `PounceApp`.
- `PounceApp`: `SearchCoordinator`, `PanelModel` (`@Observable`), `PanelController`, `LauncherPanel`
  (`NSPanel`) with `NSGlassEffectView`, the result list with keyboard handling and footer from
  `actions(for:)`, `IconCache`, `HotkeyService` (KeyboardShortcuts), Spotlight conflict detection
  (`com.apple.symbolichotkeys` keys 64 and 65), the first-launch Shortcut step, the Settings window with
  General and Features panes, menu items, `en` + `pl` strings and the Phase 1 accessibility criteria.
- `AppsPlugin` target and test target, registered with one line in `PluginRegistry`: `AppScanner`,
  `AppMetadataWatcher`, dedupe by bundle ID, aliases, `apps.json` cache, `AppLauncher`, actions.
- `PounceKit` additions (additive only, R8): `PluginContext.cachesDirectory`, `ActionContext.query`,
  `WorkspaceClient.openApplication(at:options:)` with a default.
- DEBUG-only QA flags: open the panel with a mode and query, open Settings or the onboarding step,
  seed settings, fake the Spotlight shortcut state; never register global hotkeys in QA mode.
- Spike 1.2: panel over full-screen apps with `.floating` + `.fullScreenAuxiliary`, `.statusBar`
  fallback ready behind `app.panelLevel`.

## Non-goals

- Clipboard (Phase 2) and file search (Phase 3); Permissions and Advanced panes, welcome screen,
  landing page (Phase 4).
- Section reordering in Features (only one search section exists until Phase 3).
- The `om-auto-review-pr` loop (a separate reviewer runs it).

## Implementation Plan

### Phase 1: Core matching and ranking

1.1 `TextNormalizer` + `FuzzyMatcher` (tiers, highlight ranges) with unit tests ("vsc" → Visual Studio
Code, "kalk" → Kalkulator, "ł" → "l", stable tier order).
1.2 `ranking.sqlite` + `usage_stat` + `query_association` + `UsageRepository` as `UsageRecorder`, and the
`Ranker` in `PounceCore` (spec step 1.6). Test: after 3 picks of Terminal for "te" it is first, but an
exact match of another app still wins.

### Phase 2: Apps plugin

2.1 `AppsPlugin` target (one line in `PluginRegistry`): `AppScanner`, `AppMetadataWatcher`, dedupe,
aliases, `apps.json` cache, search source (spec step 1.3) with fixture tests.
2.2 `AppLauncher` (`openApplication`, `yieldActivation`) and the ⌘Enter action (spec step 1.5) with
unit tests for the open configuration and the actions.

### Phase 3: Panel, hotkey, settings

3.1 `LauncherPanel`, `NSGlassEffectView`, `PanelController`, `PanelModel`, `SearchCoordinator`,
`HotkeyService`, keyboard table (spec step 1.2) with model tests; spike 1.2.
3.2 `IconCache` and the result list, footer, accessibility (spec step 1.4).
3.3 Spotlight conflict detection, Shortcut onboarding step, Settings (General, Features), menu items
(spec step 1.2b) with parser, default-shortcut and toggle tests.
3.4 QA flags, `docs/qa.md`, `AGENTS.md` refresh, strings.

## Risks

- Spike 1.2 (panel over full-screen apps) needs a full-screen app and Space switching: manual QA.
- KeyboardShortcuts ships a resource bundle; the app bundle must carry it where `Bundle.module` looks.
- `NSMetadataQuery` would surface the tester's real apps: QA turns it off and uses a fixture root.

## Progress

PR: #4

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Core matching and ranking

- [x] 1.1 TextNormalizer and FuzzyMatcher — 703ac31
- [x] 1.2 ranking.sqlite, UsageRepository and Ranker — 21cee51

### Phase 2: Apps plugin

- [x] 2.1 AppsPlugin target, scanner, metadata watcher and search source — b603bb6
- [x] 2.2 AppLauncher and result actions — b603bb6

### Phase 3: Panel, hotkey, settings

- [x] 3.1 LauncherPanel, PanelModel, SearchCoordinator and HotkeyService — 63af9bc
- [x] 3.2 IconCache, result list, footer and accessibility — 63af9bc
- [x] 3.3 Spotlight conflict detection, Shortcut step and Settings window — 63af9bc
- [x] 3.4 QA flags, docs and strings — 63af9bc, 45d588a
