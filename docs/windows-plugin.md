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

Window-owned UI details that QA found: the Layouts window keeps its frame in the plugin settings (never the window
system's autosave), the grid editor's list marks the zone its detail shows, safe mode has its own banner
(`StartError.failureStatus`, `PluginFailureStatus` in `LintelKit`), and every localized literal of the plugin has a Polish
catalog key (`LocalizationCoverageTests`).

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

## An app that does not answer

A window is only "gone" when its app says so. `WindowClient.readWindows(tracked:)` returns the windows with what the read
could not see: `unreachable` processes (the app's window list timed out) and `unreadable` windows (listed, but their
attributes timed out). The verdict comes from the read that failed, not from a second probe (`isResponding` is only the
default's fallback and a diagnostic); recovery classifies a missing journal window the same way (unreachable: failed, not
"on another Space"). `AXWindowClient` answers `.timedOut`, not `.windowGone`, when it cannot reach an app, and the
mapping of an AX error to "unreachable / no windows" is a pure function (`WindowGeometry.listOutcome`, tested, including
a dead process, which has no windows and keeps none). The snapshot carries `unreachable` and `unreadable`; the reducer
keeps those windows, parked or not, and the next switch or event retries them. While a snapshot could not read something
the engine looks again by itself (`WindowEngine.unknownRetry`, 5 s, doubling up to `unknownRetryLimit`, 60 s) until a read
lists the windows or says they are gone, so a window that closed while its app hung is dropped soon after the app answers. Residual: a window that closes
while its app does not answer stays tracked until the app answers (or the process ends: `appTerminated` drops them).
A process whose park timed out, or that a snapshot could not read, is marked `unresponsive` (only a process the engine
holds a window of: the marks are pruned to the held processes after every input, and `readWindows(tracked:)` only reports
tracked processes, so an app that is permanently unresponsive or has no Accessibility arms nothing and is never marked; the AX client still reads every regular app on each snapshot, it only ignores the failed read of an untracked one). While a held
process is marked the engine looks again by itself after 5 s, then 10, 20, 40 and every 60 s at most (the wait is reset
when no held process is marked), so an app that recovers and stays idle has its windows parked and a window that closed
meanwhile dropped without waiting for a switch or an event. The next event from one of its windows also reconciles
parking at once.

## Snap overlay latency

The first move of a window on a workspace whose kind offers snap targets is flushed at once (`WindowEngine.ingest`:
leading edge, only when no flush ran in the last tick); later moves are coalesced by the 30 ms tick as before. The overlay's
panels are built when the plugin starts (`ZoneOverlayPanels.prewarm()`). The budget is 150 ms for the overlay to appear after the first drag event (owner decision 2026-11-10; median 127 ms,
p95 132 ms measured in QA, about 110 ms of it the app and system delivering the Accessibility notification); see
`docs/perf.md`.

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
the journal, instead of reporting zero. Both also wait for a recovery pass that is already running, but only up to
`WindowsPlugin.restoreWaitBudget` (10 s, `JournalOwner.exclusive(within:clock:)`): a pass stuck on a hung app makes
Erase Data refuse and the button say "still being put back" instead of holding the host's queue. The bound covers the
wait for the journal only; a pass that got its turn runs to the end and answers.

*Reset state* restores every window, then starts over: the stored membership and layouts and the layout assignments are
cleared on disk, and the running engine (`EngineCommand.resetState`) clears its own membership, layout states and
placement hints and gives every window to the workspace shown on its display (a window that is still parked by its
home display), writing the new values over the cleared file. The journal is never forgotten.

## Tests

`FakeWindowClient` scripts latency-free behaviours (hung apps, refusals, snap-backs, a stall until released) and
records every call. Time is a `VirtualClock`; tests wait with barriers (`settle()`, `waitForWork()`, `waitUntilStalled`,
`OrderedActions.waitUntilEmpty()`), never with real sleeps. Where a test must wait for a count (a waiter parked in a
queue) it polls with `Task.yield()` under an iteration cap that fails the test instead of hanging it
(`WaiterLeakTests`); no wait relies on a number of yields. TSan runs the engine, recovery, strategy and journal
suites in CI. Every windows suite carries a one-minute `.timeLimit`, but measured with a mutant (a removed `cancel()`) the limit does
**not** interrupt an await that ignores cancellation: the run hung until it was killed. So the tests that guard a
bound do not await the code under test directly: they run it with `bounded(_:_:)` / `boundedMain(_:_:)` (a task whose
answer the test polls with the capped `eventually(_:_:)`), which fails cleanly in a fraction of a second (the same
mutant fails in 0.12 s). Other waits (`waitForSleepers`, `waitUntilStalled`, a plain `await task.value`) can still hang
instead of failing if the code under test breaks; the time limit and CI's own timeout are the backstop there.

## Menu bar strip: how a click is mapped (round 13)

The system delivers a click on a status item at the item's centre, so the event's own x always named the middle box.
`StripLayout.clickX` takes the cursor's screen x (`NSEvent.mouseLocation`) when it lies inside the item's window and
the event's x otherwise; the image's origin inside the button comes from the button cell's drawn image rect. Each box is
an accessibility element with its selected state. The mapping is tested with numbers observed in QA; it has not been
checked on a real menu bar by an agent (`docs/qa.md`).
