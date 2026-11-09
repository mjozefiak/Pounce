# Window Management plugin (`Sources/WindowsPlugin/`)

The design is `.ai/specs/2026-11-09-window-management.md`; this page is the map of what exists. The plugin is
registered in `PluginRegistry` and off by default.

## Rules that never change

- **Nothing moves unless the plugin is on and Accessibility is trusted.** The engine's `canMove` gate and the
  `AccessibilityGate` (one place that shows the HUD message) enforce it.
- Window titles and bundle ids are never logged or stored (titles live in memory only, in the engine's tracked
  windows). Plugin code never traps (no `fatalError`, `try!` or force unwrap).
- Windows are parked only after the journal write succeeded; a crash leaves the journal, and recovery puts the
  windows back at the next launch, even when the plugin is off.

## Pieces

| Area | Types |
|---|---|
| Port and client | `WindowClient` (LintelKit), `AXWindowClient`, `AXObservationHub`, `AXEventBuffer` (LintelApp, `Ports/`): private `_AXUIElementGetWindow` through `dlsym` with a self-check, a per-process serial queue, one bounded stream that queues a `.resync` on overflow. `QAWindowClient` for `--qa-windows`. |
| Engine | `WindowEngine` (actor), `EngineReducer` (pure) with `Engine/Reducer/ReducerContext+*` and `LayoutPlanner`, `EffectExecutor` + `LaneScheduler` (one lane per process for frame changes and focus, one for the journal and stored state), `EventCoalescer` (the one coalescer), `Watchdog`, `TimeSource` (the one injected clock). |
| Layout strategies | `Layout/` (`LayoutStrategy`, `LayoutRegistry`, `AnyLayoutState`, `AnyLayoutConfig`, `LayoutCommand`), `Tiling/TilingStrategy`, `Zones/ZonesStrategy`, `FreeStrategy`. |
| State and recovery | `StateStore` (`Plugins/windows/state.json`), `JournalOwner` (one per app instance and plugin, a typed `PluginServiceKey` of `PluginContext.services`, torn down when the host quits), `WindowRecovery`, `AccessibilityTrust`. |
| Runtime and UI | `WindowsRuntime` (exists only while active), `LayoutCommands`, `AccessibilityGate`, `ReportPump`, `EngineConfigBuilder`, `WindowsComposition`, `WorkspaceStripController`, `WindowsHUDPanel`, `ZoneDragController`, `ZoneOverlayPanels`, the Layouts window and grid editor (`Layouts/`), the settings pane (`Settings/`). |

## Engine, in short

`WindowEngine.reduceAndDispatch` reduces every queued input synchronously, in order, so it never waits for an app.
The effects go to the executor: each frame change is queued on the lane of its process and each result comes back as
an `.applied` input; a request whose generation is no longer the newest for its window is dropped when its turn
comes, and a result older than the newest request is dropped by the reducer. The echo window of a frame change starts
when it is sent (`.frameStarted`), so a queued change cannot let its own events through as user moves.

`send` and `submit` return when the work their input caused has run, or after `commandBudget` (2 s on the engine's own
injected clock): a hung app delays only its own lane and the completion of a user command by at most that bound, and a
call whose bound fired leaves nothing behind (the ledger drops its waiter). `WindowEngine.restoreAllWindows` is not
bounded (its report counts what was really put back); the callers bound it: `WindowsRuntime.restoreAllWindows` after
5 s answers with what is still parked (`failed: N`, shown as "Not responding: N"), and `WindowsRuntime.stop` bounds
the whole stop (re-grant task, queued actions, restore, engine shutdown) by `stopBudget` (5 s). After `stop()` the
engine's calls return at once, and `stop()` awaits the event pump. Events are flushed by one serial loop (a flush is
strictly after the previous one), and the engine subscribes to the client before it takes its first snapshot.

Starting is bounded too: `WindowsRuntime.start` takes the journal first and gives up after 5 s when an earlier run
still holds it (`StartError.stillStopping`: the pane says "Still stopping" and Try Again works once the old engine
is done); `PluginHost` bounds every `activate()` (20 s) so a stuck start cannot hold up a quit.

## Layout strategies

A strategy owns its kind's state (an opaque `LayoutStateValue`), its configuration (`makeConfig` from the settings
and stored data) and the commands it understands (`LayoutCommand` id plus payload; the shared enums name no verb).
The reducer, the state and the store know no kind: per-kind state is stored as opaque JSON under the kind's name
(`workspaces[n].<kind>` in `state.json`), and a kind this build does not know is kept and written back unchanged.
`LayoutKind` is an open identifier; a new strategy is one new type and one line in `LayoutRegistry.standard`. The
surface a strategy exposes reaches the pane and the runtime too (`displayName`, `usesLayoutLibrary`, `summaryParts`,
`offersSnapTargets`, `makeConfig`): there is one registry, built once by `WindowsPlugin` and injected into the
engine, `EngineConfig`, `LayoutCommands`, the settings model and the Layouts window; the cycle of *Toggle layout*
and the kinds the pane offers are the registry's. A kind named like a `state.json` key (`order`) is left out.
`ToyStrategyTests` proves it with no production change, through the engine, the pane, the settings and the command.

`LayoutCommand` ids are namespaced strings with an opaque JSON payload (`layout.focus`, `tiling.join`, `zones.slot`):
the trade-off is that a typo is caught by a test and not by the compiler, in return for shared enums that name no
verb. Each kind keeps its ids and payload types next to its strategy.

## Journal ownership

`JournalOwner` holds the only `StateStore` of a storage folder. Either the running engine owns the journal (it holds
a lease) or one recovery pass does. `beginEngine()` waits until the journal is free; a recovery pass answers
`.engineRunning` or `.engineStopping`; a stale lease changes nothing. The runtime gives the journal back only once
the engine has really stopped.

## Erase Data and Restore all windows

*Erase Data* refuses (`WindowsPlugin.EraseRefused`, so the host keeps `Plugins/windows/`) while any window may still be
parked: the old engine has not handed the journal back within 10 s, an app did not answer, or Accessibility is off.
*Restore all windows* without a running plugin says "Windows are still being put back" when the engine still holds
the journal, instead of reporting zero.

## Tests

`FakeWindowClient` scripts latency-free behaviours (hung apps, refusals, snap-backs, a stall until released) and
records every call. Time is a `VirtualClock`; tests wait with barriers (`settle()`, `waitForWork()`, `waitUntilStalled`,
`OrderedActions.waitUntilEmpty()`), never with real sleeps. TSan runs the engine, recovery, strategy and journal
suites in CI.
