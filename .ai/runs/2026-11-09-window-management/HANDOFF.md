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
- H-3: open `LayoutKind`, strategies own state, configuration and commands (`LayoutCommand` id plus payload), `JSONValue` in `Support/`; `ToyStrategyTests` proves a fourth kind needs no production change (since round 4 that includes its own options, commands and settings rows).
- M-4: `JournalOwner` comes from `PluginContext.services` (no registry global), with leases; `ReportSink` replaces a task hop.
- M-2/M-6: `LaneScheduler`, `EffectExecutor`, `ReportPump`, `AccessibilityGate`, `EngineConfigBuilder`; the echo window starts when a frame change is sent; commands wait at most `commandBudget`.
- M-5: `LayoutPlanner` is a pure read-only type and the reducer parts are layers (`ReducerLayeringTests`). `EngineState` was not regrouped: ~150 sites read its fields, and grouping would only move names.
- B: one coalescer (the engine's); `AXEventBuffer` bounds the stream and queues a `.resync` on overflow (ADR 0009 addendum).
- M-9: no real sleeps or yield counting in the windows plugin and its tests (the `FakeWindowClient` has no latency option; `WaiterLeakTests` poll a waiter count with `Task.yield()` until it is reached, and every wait there ends on a condition, not on a count); the PluginHost tests use gated and virtual clocks and per-environment services instead of statics.
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

## Round 4 (independent audit of round 3)
- H-A (layout abstraction made real): `LayoutOption` (points or choices; global setting key and per-workspace override) replaces `gaps`/`rootOrientation` in `ResolvedLayout`/`WorkspaceOverride`/`LayoutConfig`; the override record stays the flat v1 JSON (`kind`, `innerGap`, `outerGap`, `rootOrientation`) so nothing stored changes. `LayoutStrategy` also declares `options`, `commands` (`LayoutCommandSpec`) and `libraryLayoutID`; strategies may add settings rows (`LayoutSettingsProviding`). The pane draws options and rows from the registry (Free shows none, Zones its two layout pickers), the command catalogue and the modifier-family rows come from the registry, `LayoutConfig(settings:registry:)` is the one construction, `LayoutCommands` has no `ZonesConfig`, `TilingDirection` is `LayoutDirection`. `ToyStrategyTests` adds a toy with its own option, command and row and drives them through the pane model, settings, engine and catalogue. Still not open (documented in the spec and `docs/windows-plugin.md`): the closed `ShortcutFamily` list, the shared directional verbs, and the layout library/Layouts window, which are the Zones feature.
- M-A: `WindowsRuntime.start` has a one-life phase checked after every await, a late journal lease is handed back, `WindowEngine.start()` does nothing after `stop()`, `StartError.failed` for other errors (cancellation reports nothing); `StartStopRaceTests`.
- M-B: `PluginHost.eraseData` activates an enabled plugin again after a refused or failed erase (host test).
- M-C: `OrderedActions.finish()`, cancellable `JournalOwner` waits (`Pass.cancelled`), `ReportPump.finish()` drops reports already queued; `WaiterLeakTests`.
- M-D: `PluginServices` is a protocol (a port) in `LintelKit`, `AppPluginServices` in `LintelApp`, `PluginContext.pluginID` explicit, tests use their own services object; recorded in `BACKWARD_COMPATIBILITY.md` (never released, so a move breaks nothing).
- Lows: a park for a window cleared in the same batch is dropped; test hangs guards without real time; test-only API under `#if DEBUG`; one event entry point (`subscribe()`); `isResponding` default `false`; Reset state keeps the journal while windows are parked; `unsafeBitCast` type-checked; `ReducerLayeringTests` is described as a text lint, not a guarantee; command ids stay namespaced strings (documented trade-off).

## Round 5 (final polish)
- Snapping is generic: `DragZone.command` is supplied by the strategy that offers the target and `WindowsRuntime.snap` sends it; the toy kind snaps. The strategy protocol is split into small capabilities (`LayoutLibraryProviding`, `SnapTargetProviding`, `SettingRowProviding`), reached through typed accessors with `nil` defaults (no dynamic casts); settings rows get a narrow `LayoutSettingsContext`, not the pane model. `LayoutRegistry` and `LayoutCapabilities` are their own files; `WindowsRuntime` is split into `+Lifecycle` and `+Recovery`.
- Claims made exactly as strong as the code: the layout library, the Layouts window, the grid editor, the layout slots and the `defaultZoneLayout.*` keys are Zones-owned and listed as such (docs and spec); the pane's default-layout help and the Layouts tooltip no longer name kinds.
- "Use default" in the kind picker stores no kind (`setOverrideChoice`); a stored `"default"` reads as none.
- `BACKWARD_COMPATIBILITY.md` states the real `WindowClient` defaults (`isResponding` is `false`, `subscribe()` has none, `processStart` is `nil`).
- `JournalOwner.waitUntilIdle(within:clock:)` cancels its wait on timeout (start and erase use it); the late-lease branch of `acquireJournal` is reached and tested; `StateStore.reset` never forgets the journal, which closes the reset race; `recover()` counts the launch only after a pass that ran.
- Lows: bounded polling in `WaiterLeakTests`, `LayoutOption.help` rendered, strategy command ids cannot take plugin-owned ids, `AppPluginServices.holds` is DEBUG-only and its invariant documented, `UnsharedPluginServices` logs an error when asked, `abandonStart` awaits the pump, `ReportPump` finishes its stream when freed, the runtime phase is in the docs, Zones command count has its own constant.

## Next concrete action
QA gate and merge by the owner.
