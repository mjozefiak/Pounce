# Window management (workspaces, tiling, zones, layout library) - execution plan

Run: `2026-11-09-window-management` · Branch: `feat/window-management` · Mode: Spec-implementation run (om-auto-create-pr-loop, owner rule: one branch and one PR for all four phases)
Source spec: `.ai/specs/2026-11-09-window-management.md` (spec PR #66; Refs #66, never Closes)

## Tasks

> `Status` is `todo` or `done`. First non-done row is the resume point.

| Phase | Step | Title | Exec | Status | Commit |
|-------|------|-------|------|--------|--------|
| 1 | 1.1 | Spike ADR (not yet measured; needs a real Mac) | dispatch:capable | done | 9ebc9eb |
| 1 | 1.2 | LintelKit contract: WindowClient, types, PluginContext.windows, recoverAtLaunch, PluginHost step | dispatch:capable | done | 036f89e |
| 1 | 1.3 | WindowsPlugin skeleton, WindowsSettings, manifest (not registered) | dispatch:capable | done | f467cf0 |
| 1 | 1.4 | Workspace model (pure) | dispatch:capable | done | 87bc5cf |
| 1 | 1.5 | StateStore with write-through hidden journal | dispatch:capable | done | 1978ffd |
| 1 | 1.6 | WindowEngine reducer, effects, coalescer, watchdog, fake client, TSan CI | dispatch:capable | done | 2cd9cb3 |
| 1 | 1.7 | Crash recovery, restore HUD, re-grant polling | dispatch:capable | todo | |
| 1 | 1.8a | Window id lookup and self-check | dispatch:capable | todo | |
| 1 | 1.8b | AX observation | dispatch:capable | todo | |
| 1 | 1.8c | Batched setFrame and wiring | dispatch:capable | todo | |
| 1 | 1.9 | Commands, HUD, window switcher, keyboard-layout check | dispatch:capable | todo | |
| 1 | 1.10 | Workspace strip | dispatch:capable | todo | |
| 1 | 1.11 | Settings pane, onboarding, diagnostics | dispatch:capable | todo | |
| 1 | 1.12 | Docs, QA, --qa fake client, registration, default shortcut tests | dispatch:capable | todo | |
| 2 | 2.1 | TilingTree and frames (pure) | dispatch:capable | todo | |
| 2 | 2.2 | Directional navigation (pure) | dispatch:capable | todo | |
| 2 | 2.3 | Resize, join, orientation, balance (pure) | dispatch:capable | todo | |
| 2 | 2.4 | Engine integration for tiling | dispatch:capable | todo | |
| 2 | 2.5 | Tiling commands, settings, per-workspace overrides | dispatch:capable | todo | |
| 3 | 3.1 | GridLayout and stock templates (pure) | dispatch:capable | todo | |
| 3 | 3.2 | Assignment store and assignments.json | dispatch:capable | todo | |
| 3 | 3.3 | Zone placement and zone commands | dispatch:capable | todo | |
| 3 | 3.4 | toggleLayout and conversion | dispatch:capable | todo | |
| 3 | 3.5a | Drag state machine (pure) | dispatch:capable | todo | |
| 3 | 3.5b | Snap overlay and monitors | dispatch:capable | todo | |
| 3 | 3.6 | Layouts window (stock layouts) | dispatch:capable | todo | |
| 3 | 3.7 | Polish pass and perf docs | dispatch:capable | todo | |
| 4 | 4.1a | LayoutRepository | dispatch:capable | todo | |
| 4 | 4.1b | LayoutImporter and export | dispatch:capable | todo | |
| 4 | 4.2 | Grid editor | dispatch:capable | todo | |
| 4 | 4.3 | Layouts window (library) and layout slots | dispatch:capable | todo | |
| 4 | 4.4 | Polish: lintellayouts type, open handler, docs | dispatch:capable | todo | |

## Phase checkpoints (owner rule)
After the last step of each phase: full gate (build, release build, test, format lint, TSan on engine/plugin tests), independent fresh-context review with fixes as separate commits, QA with the fake window client, one `Phase N checkpoint` PR comment with a manual QA checklist.

## Standing constraints
Plugin registered but `defaultEnabled: false`; no window moves unless enabled and Accessibility trusted; no traps in plugin code; never log titles or bundle ids; LintelKit additive with defaults, listed in BACKWARD_COMPATIBILITY.md; no measurements without a real run.
