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

## Round 2 (second architecture review)
- H-1/M-3/M-7: one serial flush, a stopped engine, `WindowClient.subscribe()` before the snapshot.
- H-3: open `LayoutKind`, strategies own state, configuration and commands (`LayoutCommand` id plus payload), `JSONValue` in `Support/`; `ToyStrategyTests` proves a fourth kind needs no production change.
- M-4: `JournalOwner` comes from `PluginContext.services` (no registry global), with leases; `ReportSink` replaces a task hop.
- M-2/M-6: `LaneScheduler`, `EffectExecutor`, `ReportPump`, `AccessibilityGate`, `EngineConfigBuilder`; the echo window starts when a frame change is sent; commands wait at most `commandBudget`.
- M-5: `LayoutPlanner` is a pure read-only type and the reducer parts are layers (`ReducerLayeringTests`). `EngineState` was not regrouped: ~150 sites read its fields, and grouping would only move names.
- B: one coalescer (the engine's); `AXEventBuffer` bounds the stream and queues a `.resync` on overflow (ADR 0009 addendum).
- M-9: no real sleeps or yield counting in the windows plugin and its tests (the `FakeWindowClient` has no latency option); the PluginHost tests use gated and virtual clocks and per-environment services instead of statics.
- M-10: `docs/windows-plugin.md` holds the detail; the AGENTS row is short; `StateStore.close()` closes (writes after it throw `.closed` until `load()`).
- The spec (PR #66) is rev 6 and identical to `.ai/specs/2026-11-09-window-management.md` here.

## Round 3 (independent audit of round 2)
- H-1: `restoreFromJournal` returns the `Pass`; *Erase Data* waits (10 s) for the journal and throws `EraseRefused` (the host keeps the folder) while windows may be parked, the engine has not handed the journal back, or Accessibility is off; *Restore all windows* without a runtime shows "still being put back". Decision: refusing erase also when only Accessibility is missing, because the journal is the only way back for hidden windows.
- M-1: `LayoutStrategy` also has `displayName`, `usesLayoutLibrary` and `summaryParts`; no kind switch is left outside the strategies; one registry (built by `WindowsPlugin`) is injected everywhere, the engine/builder/reducer have no default; `LayoutKind.standard` is gone; reserved kind names; `ToyStrategyTests` reach the pane, the settings and *Toggle layout*. The builder is `EngineConfig(settings:registry:...)`.
- M-2/M-3: the lease is taken before anything starts with a 5 s bound (`StartError.stillStopping`, pane row, Try Again); `WindowsRuntime.stop` is bounded as a whole; `restoreAllWindows` reports what is still parked after 5 s; `PluginHost` bounds `activate()` (20 s). Decision: the host's bound fails the plugin; the underlying activation is cancelled.
- M-4: the command bound uses the engine's injected clock; the ledger drops the waiter when it fires.
- M-5: `PluginServiceKey` (typed, per plugin, recursion-safe, torn down on host quit) replaces the string-keyed locator.
- M-6/M-7: the recovery-order test has no sleeps or statics; `stop()` awaits the pump; `StateStore` guards every write after `close()`.
- Lows: structural `ReducerLayeringTests` (declared function names, comments and strings stripped); `EngineState` clusters documented (regrouping stays the next refactor); command ids namespaced constants; `inFlight` removed (the ledger is the one count of work; the flush stages are documented); `flushEvents`, `waitForWork`, `settle` and `WindowsRuntime.settle` are DEBUG-only; the echo window is per frame in flight; `coalesce` keeps the last journal operation per window and replaces the entry of a window removed and parked again in one batch; `EngineConfigBuilder` folded into `EngineConfig`; `AccessibilityGate` and `TimeSource` kept (shared by several callers / the only place a generic clock is erased); stale comments and the AGENTS lines fixed.

## Next concrete action
QA gate and merge by the owner.
