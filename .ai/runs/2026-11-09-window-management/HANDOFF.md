# Handoff - 2026-11-09-window-management

**Branch:** feat/window-management (PR #68)
**Current step:** implementation done; the architecture-review refactor is in (see below).

## Architecture-review refactor (this PR, one commit per group)
- H1: `WindowClient.window(id:)`; events read one window, never every app.
- H2/H5: `WindowEngine` reduces synchronously and runs effects on per-process lanes plus one store lane; results come back as inputs; `send`/`submit`/`restoreAllWindows` return after their work ran.
- H3/M1: `Layout/` (`LayoutStrategy`, `AnyLayoutState`, `LayoutRegistry`) with `TilingStrategy`, `ZonesStrategy`, `FreeStrategy`; the reducer is split into `Engine/Reducer/ReducerContext+*`; `state.json` keeps each kind under its name as opaque JSON.
- H4: `JournalOwner` per storage folder (`State/JournalOwner.swift`); no global sets, no HUD singleton.
- M2/M3/M4: `LayoutCommands`, `WindowsComposition`, `WindowsPlugin+Layouts/+Recovery`, one ordered output stream, `withDeadline` in `LintelCore`.
- M5: one injected clock (`TimeSource`); tests use `VirtualClock` and barriers (`WindowsRuntime.settle()`).
- M6/M11: `checkAvailability()` (additive), async `AXObservationHub.start()`, documented refcon invariant.
- M7/M8/M9/M10: neutral shell comments, `plugins.windows.showHUD`, the switcher reads the engine's cache, `WindowEngine.state` is private (`inspect` for tests).
- L2/L3/L4/L5/L6/L8 done; L9 (grouping `PluginContext` parameters) deliberately not done: it would add a parameter without removing any and the init is already additive.

## Next concrete action
QA gate and merge by the owner.
