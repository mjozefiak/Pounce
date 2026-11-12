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
holds a window of: the marks are pruned to the held processes after every input). An app the engine holds nothing of that did
not answer the latest snapshot is kept in `unknownApps` and looked at again at most `untrackedRetryLimit` (6) times, so an app that never answers is not polled for ever and one with no Accessibility arms nothing. While a held
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
`StripLayout.resolvedClickX` takes the screen x where the mouse went down on the item (a local monitor, `PressCapture`),
else the cursor's x (`NSEvent.mouseLocation`) when it lies inside the item's window; with neither (a press from
VoiceOver or Voice Control) the strip opens its menu rather than reading the event's centre as the middle box; the image's origin inside the button comes from the button cell's drawn image rect. Each box is
an accessibility element with its selected state. The mapping is tested with numbers observed in QA; it has not been
checked on a real menu bar by an agent (`docs/qa.md`).

## Layout editor: how small a track can get

Dividers moved by the arrow keys or the numeric fields, and a zone divided by key (S, ⇧S), keep every track at 1% of the
display or more; a divide that would go below is refused with the usual message and announcement and changes nothing
(undo included). A divide by **click** is stricter: each piece must be at least 5%, so a track narrower than 10% can no
longer be divided by click; use the keyboard or the numeric fields for finer work (round 13 B2, round 15 M1).

## Menu bar strip and VoiceOver (round 16, D3: owner decision pending)

QA round 4 found that macOS shows a status item no accessibility children (only `AXPress`), so the per-box elements
added in round 13 are never seen. What VoiceOver gets: the item reads **"Workspaces, current: 2 of 4"** (updated on
every change), and its right-click or Control-click menu lists "Go to Workspace N" (the current one checked) and
"Restore All Windows"; Settings has the same instruction on the strip switch. Options for the owner: **(a)** keep one
status item and this menu as the accessible path (what is implemented; no menu bar room beyond one item); **(b)** one
status item per box (up to nine; each box is then a real item with its own label and press, at the cost of menu bar
room and the notch, and a spec decision). The one-item design is not changed here.

## Accordion, layout commands and the v2 defaults (window management v2, Phase 1)

- **Accordion** (`Layouts/AccordionLayout.swift`, kind `accordion`, last in `LayoutRegistry.standard`). The state is the
  window order (`AccordionState`, stored as `{"order": [...]}`); the focused window comes from `LayoutInput.focused`.
  `AccordionLayout.frames` is pure: every window takes the area after the outer gap (the inner gap does not apply, the
  windows overlap), the windows before the focused one are one frame that ends `padding` short of the right edge, the
  ones after it are one frame that starts `padding` in, and the focused one has its own. Because of that a change of
  focus changes two frames (a few more at the first and last window), so a quick walk through nine windows stays far
  below the watchdog's 60 changes a second (`AccordionTests`). Options: `accordionPadding` (global
  `plugins.windows.accordion.padding`, 30, 0 to 200) and `accordionOrientation` (`auto`: horizontal on a landscape
  display, vertical on a portrait one). The strategy has no gap options of its own (the ids belong to Auto-tile), so it
  reads the global gaps through `makeConfig` (`AccordionConfig`); a per-workspace gap override does not apply to it.
- **`arrangesOnFocusChange`** (`LayoutCapabilities`/`LayoutStrategy`, default `false`): the reducer arranges a workspace
  again on `windowFocused` only when its kind says so. Frame requests still go only to windows whose target changed.
- **`windows.layout.tiles` / `windows.layout.accordion`** (`LayoutCommands.setLayout`): write the kind override like
  *Toggle Layout* (a kind equal to the default clears it, overrides from a newer version are never overwritten). Pressed
  while the workspace already has that kind they flip the direction: Auto-tile through the engine command
  `toggleOrientation`, Accordion through the `accordionOrientation` option of the workspace (configuration, not state).
  They are in `WindowsCommandID.reserved`; there is no engine input for a kind.
- **Resize step**: grow and shrink send `tiling.resizeSteps` (±1). The strategy turns the setting `resize.step` (points,
  default 50) into the share of the container that `TilingTree.resize` moves, from the container's real length.
  `tiling.resize` (a share) stays for callers that want one.
- **`windows.workspace.moveToNextDisplay`**: `EngineCommand.moveWorkspaceToNextDisplay` swaps the current workspace with
  the one on the next display (wrapping); both stay shown, so nothing is parked. The focus goes to the moved
  workspace's most recently used window. With one display the engine reports `EngineNotice.singleDisplay` and the HUD
  says "Only one display" (shown even when the workspace HUD is off, like "No focused window").
- **Default shortcuts and the migration**: J/K focus and move left/right, ⌥/ Auto-tile, ⌥, Accordion, ⌥⇧Tab next
  display; `toggleLayout` has none. `ShortcutMigration` (run once from `activate()`, marker
  `plugins.windows.shortcutDefaultsVersion`) moves stored shortcuts that are still equal to the v1 default, frees the
  keys first and never gives a key another command holds. The check for shortcuts that type characters covers the whole
  catalogue (`WindowsCommandID.shortcutCommandIDs`).
- **New defaults**: nine workspaces, gaps 10/10, accordion padding 30. A stored value always wins.

## Configure window, workspace names and rules (window management v2, Phases 2 and 3)

- **Configure window** (`Settings/WindowsConfigureWindowController`, `WindowsConfigureModel`, `WindowsConfigureView`): a
  plugin-owned window (like the Layouts window: built on first use, rebuilt after a close, closed when the plugin is
  switched off) with a sidebar: **Shortcuts** (every command with the shell's own recorder, search by every word, groups,
  a warning icon for a shortcut that types a character, a conflict line with *Replace*, *Reset* per row and *Reset All*
  behind a destructive confirmation, and one *Modifiers* row for each numbered family), **Workspaces** (name, layout kind,
  gaps and direction of each workspace; the effective value is always shown, "Default · 10 pt"), **Gaps & Layout** (the
  default kind and the global points options: gaps, accordion padding, resize step) and **Rules**. The model reads and
  writes through `WindowsSettingsModel`, so the pane, the window and the engine never disagree. The shell's recorders
  write a shortcut themselves and cannot be intercepted, so a second command on the same key is shown as a conflict
  afterwards (the list is read again every 0.7 s while the window is open) and *Replace* takes it from the other one.
  The pane in Settings keeps the basics, a *Configure…* row ("9 workspaces · 12 shortcuts · 3 rules") and Advanced loses
  the shortcut-family rows and the per-workspace summaries.
- **Workspace names** (`WorkspaceNames`, `plugins.windows.workspaceNames`): in the strip's spoken label ("Workspace 3,
  Code, 4 windows"), its menu ("3 · Code") and the HUD; the boxes themselves keep their number.
- **Rules** (`AppRules`, `RuleResolver`, `plugins.windows.appRules`): the Rules list is the floating apps plus the
  workspace rules. `EngineConfig.appWorkspaces` carries the active ones (float wins, a workspace that is off does not
  apply). The reducer applies a rule only when it first tracks a window from a `windowAppeared` input: a window that
  existed at the start, or a second window of an app, is never moved by it, and the workspace is not switched (a hidden
  workspace parks the window).
- Not done in this change: the focus border (Phase 4) needs the spike on a real Mac first (step 4.1).

## Focus at the time of a command (window management v2, Phase 0)

The engine's idea of the focused window comes from events, which can be late, coalesced or taken for echoes. So a
command that acts on the focused window (`windows.moveToWorkspace.N`, `windows.move.*`, `windows.toggleFloating`, and
the other layout commands) is run by `WindowsRuntime.run`, which reads `client.focusedWindow()` first (bounded by
`focusReadBudget`, 250 ms, through `withDeadline` on the plugin clock) and calls
`WindowEngine.send(_:observingFocus:)`: one batch of `.focusObserved(id)` and the command, so two quick shortcuts
cannot interleave their reads and commands.

- `.focusObserved` only sets `state.focused` (never switches workspace, unlike `.windowFocused`). The reducer also
  keeps `pendingFocus`: the target of its latest `.focus` effect for one second (engine time) or until a focus event
  for that window arrives. An observation of a window that is hidden, parked or unknown while a request is pending is
  the system lagging behind, so the requested window stays; any other observation wins. A differing observation is
  counted in `focusMismatches` (no ids).
- `focusOrder` is a list of windows by recency (memory only). The most recently used window of a workspace is its
  newest entry; `switchTo` gives it the focus when the focused window was hidden by the switch, and a move hands the
  focus to it instead of the last window in order. With no window on that workspace the focus goes to a window visible
  on another display (most recently used, else last in order), and with none visible nothing is focused: the system
  focus never stays on a parked window.
- `moveFocusedWindow` and `toggleFloating` act only on a window whose workspace is shown. When none is focused, or the read did not answer,
  nothing moves and the HUD says "No focused window". `focus.*` stays tolerant: with an unmanaged window focused (Finder,
  Lintel) it counts from the last managed one (`previousFocus`).
- A window that is parked while its workspace is shown is mid-restore (a second shortcut can arrive before the first
  one's results are reduced), so the guard looks at the workspace, not at `state.parked`.
- A switch keeps the focus only when the focused window was already on a shown workspace *before* the switch. A window
  the switch just revealed was parked a moment ago and the system's focus is not really there (re-QA D1-3), so it is
  asked for explicitly like any other hand-off target. When a move or switch leaves no visible window at all (single
  display, everything else hidden) nothing is focused and the system focus stays where it is: the engine refuses to act
  on it, and stealing the activation for Lintel's own window was judged worse than typing into a parked window.
- `AXWindowClient.focus` raises the window, sets AXMain and AXFocused on it, sets the app's focused window and makes the
  app frontmost by Accessibility (not only `NSRunningApplication.activate()`, which needs Lintel to be active). The
  extra attributes are the proposed fix for a parked window of the same app keeping the focus; real-desktop verified: no.

