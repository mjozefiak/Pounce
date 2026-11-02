# Execution plan: app suggestions, Phase 1

Source doc: .ai/specs/2026-11-01-app-suggestions.md
Engine: om-auto-create-pr (steps: 12, --loop: no)

## Goal

Ship Phase 1 of the app suggestions spec: `AppsPlugin` learns which apps the user keeps in front (live `NSWorkspace` observation plus a one-time Spotlight seed) and the empty search panel shows a "Suggested" section of 5 apps above "Recently Used", launched with ⌘1–⌘5, with a Settings → Applications pane to turn it off, clear the data and restore hidden apps.

## Scope

- `PounceKit` (additive): `SuggestionSource`, `PouncePlugin.suggestionSources`, `Candidate.badge`, three `WorkspaceClient` requirements.
- `Package.swift`: `AppsPlugin → PouncePersistence` (owner-approved, PR #10 comment 6576047488).
- `AppsPlugin`: `ActivityStore`, `SuggestionEngine`, `ActivityTracker`, `ActivitySeeder`, `AppSuggestionSource`, the Apps settings pane, DEBUG QA hooks.
- `PounceApp`: workspace port, `PluginHost.activeSuggestionSources`, `SuggestionSourceAdapter`, the Suggested section in `SearchCoordinator`, ⌘1–⌘5 and the row hint/badge, `QAOptions`/`AppEnvironment` QA keys, Advanced pane note.
- Docs: `BACKWARD_COMPATIBILITY.md` §1/2/3/5, `AGENTS.md`, MVP spec footnote, `docs/perf.md`, `docs/qa.md`, `docs/index.html`, release note.

## Non-goals

- Phase 2 (steps 13–15): the `apps.suggestions` panel mode, the global shortcut and ⌘n in list modes without filters.
- Any change to `ranking.sqlite`, `Ranker`, `UsageRecorder` or `AppMetadataWatcher`.

## Implementation Plan

### Phase 1: app suggestions in the panel

Steps follow the spec's Implementation Plan 1–12 one to one.

## Risks

- `risk-high`: protected contract (`PounceKit`), new `Package.swift` edge, new on-disk file and settings keys, default-on activity collection (owner-approved).
- Local/manual checks (steps 1, 4, 5, 6, 11) need a GUI session; anything not run is reported as such in the PR body.
- Open dictation PRs (#15–#19) also extend `PounceKit`; whichever merges second resolves additive conflicts.

## Review fixes

- Review pass (inline om-code-review): no blockers; minors 1–3 fixed in 1910468, Clear-during-seed test added; deferred: test that the seed waits for the first scan, `.regular` filter for the frontmost app at tracker start, shell-side QA list key.

## Progress

PR: #20

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: app suggestions in the panel

- [x] 1.1 Activation and idle port — d251da7
- [x] 1.2 ActivityStore — ba4640c
- [x] 1.3 SuggestionEngine — a3e486d
- [x] 1.4 ActivityTracker — 46e9c85
- [x] 1.5 ActivitySeeder — a0d5b90
- [x] 1.6 Settings → Applications pane (UI only) — 9cc0b4c
- [x] 1.7 Contract — 4486645
- [x] 1.8 AppSuggestionSource — 1b76b55
- [x] 1.9 Suggested section in SearchCoordinator — 2a73e6e
- [x] 1.10 Turn on collection — 12b52a6
- [x] 1.11 ⌘1–⌘5 and row appearance — ebf8edf
- [x] 1.12 Hidden list, localization and documentation — 9f29952
