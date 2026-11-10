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
| Runtime and UI | `WindowsRuntime` (exists only while active), `LayoutCommands`, `AccessibilityGate`, `ReportPump`, `WindowsComposition`, `WorkspaceStripController`, `WindowsHUDPanel`, `ZoneDragController`, `ZoneOverlayPanels`, the Layouts window and grid editor (`Layouts/`), the settings pane (`Settings/`). |

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
`LayoutKind` is an open identifier; a new strategy is one new type and one line in `LayoutRegistry.standard`. What a
strategy declares reaches the pane, the settings and the command catalogue as data:

- `options` (`LayoutOption`: points or choices, a default, an optional global setting key under `plugins.windows.`).
  The plugin stores the values without interpreting them: the global value in its setting, a workspace's override
  flat next to `kind` in `plugins.windows.workspaces` (the shape of the first version, whose options were `innerGap`,
  `outerGap` and `rootOrientation`), and delivers them in `LayoutInput.resolved` (`ResolvedLayout.int(_:)`,
  `string(_:)`). Only the options of the kind in use apply; another kind's values stay stored. Option ids are unique
  across the registry (a strategy that repeats one, or `kind`, is left out like a reserved kind name).
- `commands` (`LayoutCommandSpec`): the plugin's catalogue is the shared verbs (focus and move to a neighbour with
  `LayoutDirection`, toggle floating), the registry's commands (an id the plugin owns, `WindowsCommandID.reserved`,
  is refused), the layout-library commands when any kind has the `library` capability, and *Toggle layout*.
- `summaryParts(_:)` for the line in the per-workspace summary.
- Optional capabilities, each its own small protocol that a strategy returns itself for from a typed accessor with a
  `nil` default (no dynamic cast anywhere): `library` (`LayoutLibraryProviding`: the kind assigns layouts from the
  library; *Next zone layout* asks it which one is in effect), `snapping` (`SnapTargetProviding`: the kind offers snap
  targets; every `DragZone` carries the `LayoutCommand` that snaps, and the plugin sends that command for the dragged
  window, so snapping is generic) and `settingRows` (`SettingRowProviding`: rows for settings that are not options,
  built from a narrow `LayoutSettingsContext`: the settings, the library's layouts and an "applied" callback, not the
  pane model).

There is one registry, built once by `WindowsPlugin` and injected into the engine, `LayoutConfig(settings:registry:)`
(the one construction of the defaults, used by `EngineConfig` and the pane), `LayoutCommands`, the settings model and
the Layouts window; the cycle of *Toggle layout* and the kinds the pane offers are the registry's. A kind named like a
`state.json` key (`order`) is left out. `ToyStrategyTests` proves a fourth kind with its own option, command, settings
row and snap target needs no production change, through the engine, the pane model, the settings, *Toggle layout*,
snapping and the command catalogue.

What is not open, and is documented rather than hidden: the closed `ShortcutFamily` list (a kind's commands are bound
one by one, or join an existing family) and the shared directional verbs. The **layout library** is the Zones feature
and is not generic over layout formats: the Layouts window and its matrix, the grid editor and the layout slots work on
`GridLayout`, `LayoutsModel` builds `ZonesConfig` directly, the settings keys `defaultZoneLayout.*` and
`WindowsSettings.defaultZoneLayout` are Zones' own, and a kind can only join the library by returning a `GridLayout`
id from `libraryLayoutID`. Nothing else in the pane, the settings model, the command catalogue or the engine names a
kind.

`LayoutCommand` ids are namespaced strings with an opaque JSON payload (`layout.focus`, `tiling.join`, `zones.slot`):
the trade-off is that a typo is caught by a test and not by the compiler, in return for shared enums that name no
verb. Each kind keeps its ids and payload types next to its strategy.

## The runtime's one life

`WindowsRuntime` has a phase: `idle`, `starting`, `running`, `stopped`, and lives once. `start()` checks it after every
await; a `stop()` that comes first (a disable, the host giving up on a start that hangs, a failed self-check) or a
cancelled caller ends the start with `CancellationError`, tears down what it had created, and hands back a journal lease
it took after the stop. `WindowEngine.start()` is a no-op once `stop()` has run, and a start that a stop overtook awaits
the pump it created. A waiting `waitUntilIdle` (`JournalOwner.waitUntilIdle(within:clock:)`) is a task the caller cancels
when its budget runs out, so nothing stays parked in the journal's queue after a timeout.

## Journal ownership

`JournalOwner` holds the only `StateStore` of a storage folder. Either the running engine owns the journal (it holds
a lease) or one recovery pass does. `tryBeginEngine()` takes the lease when the journal is free and answers `nil` otherwise; `waitUntilIdle()` waits (the
runtime bounds it with `startBudget` and cancels it with its caller); a recovery pass answers `.engineRunning`,
`.engineStopping` or `.cancelled`; a stale lease changes nothing. The runtime gives the journal back only once
the engine has really stopped.

## Erase Data and Restore all windows

*Erase Data* refuses (`WindowsPlugin.EraseRefused`, so the host keeps `Plugins/windows/`) while any window may still be
parked: the old engine has not handed the journal back within 10 s, an app did not answer, or Accessibility is off.
*Restore all windows* without a running plugin says "Windows are still being put back" when the engine still holds
the journal, instead of reporting zero.

## Tests

`FakeWindowClient` scripts latency-free behaviours (hung apps, refusals, snap-backs, a stall until released) and
records every call. Time is a `VirtualClock`; tests wait with barriers (`settle()`, `waitForWork()`, `waitUntilStalled`,
`OrderedActions.waitUntilEmpty()`), never with real sleeps. Where a test must wait for a count (a waiter parked in a
queue) it polls with `Task.yield()` under an iteration cap that fails the test instead of hanging it
(`WaiterLeakTests`); no wait relies on a number of yields. TSan runs the engine, recovery, strategy and journal
suites in CI.
