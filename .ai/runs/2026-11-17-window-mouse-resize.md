# Mouse resize of a tiled window redistributes its siblings

Source doc: research report section 1 (owner request 2026-11-17); `.ai/specs/2026-11-11-window-management-v2.md` (addendum).

## Goal
Dragging an edge of a tiled window with the mouse resizes its siblings (AeroSpace-like) instead of being snapped back.

## Scope
Pure `TilingTree.adopt` in `WP/Tiling/TilingUserResize.swift`; optional `LayoutStrategy.resizing` capability (nil default); a new reducer part `ReducerContext+UserResize`; `windowMoved` branch; do-not-fight-the-drag guard in `arrangeIfRequested`; `EngineInput.userResizeSettled` armed by an injected-clock timer (~250 ms); adoption reflows throttled to <= 10/s (Watchdog). Non-goals: Zones/Free resize, #70 files beyond trivial switch cases, wake/strip work.

## Risks
Any non-echo resize of a tiled window is adopted (an app resizing itself); mitigated by stubborn/echo-window guards. EngineTypes/EngineReducer conflict trivially with PR #70: rebase after #70 merges.

## Progress

PR: #95

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Pure operation and capability

- [ ] 1.1 TilingTree.adopt and the UserResizeAdopting capability with tests

### Phase 2: Engine

- [ ] 2.1 Reducer part, guard, settle input and throttle
- [ ] 2.2 Engine settle timer
- [ ] 2.3 Reducer and engine tests (watchdog, state.json round trip)

### Phase 3: Docs

- [ ] 3.1 v2 spec addendum and docs/windows-plugin.md
