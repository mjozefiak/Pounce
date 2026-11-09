# ADR 0009: Window management spike (step 1.1)

- Status: **decisions recorded, measurements pending.** The spike needs a real Mac with Accessibility granted and
  real third-party apps; an agent cannot run it. Every measurement field below says `not yet measured` and stays
  so until the owner runs the spike and fills it in (no number in this file is a measurement).
- Date: 2026-11-09
- Spec: `.ai/specs/2026-11-09-window-management.md`, step 1.1 (Q2, Q3). Number 0009: `0007` is used twice and
  `0008` is taken (checked on `main` and in the open PRs on 2026-11-09).

## Decisions

### Q2: workspaces are emulated by parking windows

A workspace that is not visible is "hidden" by moving its windows to a corner of their display with
`AXUIElementSetAttributeValue(kAXPositionAttribute)`, after writing their remembered (home) frames to the journal.
Showing the workspace sets the remembered frames back. Native macOS Spaces are not touched.

Rejected: private CGS Space calls (need SIP changes for the useful parts, break on updates), minimising (animates,
fills the Dock), `NSRunningApplication.hide()` (hides an app, so two workspaces cannot share an app).

Consequences accepted: parked windows stay parked if Lintel dies until it runs again; this is mitigated by the
write-through journal and `recoverAtLaunch` (spec: Architecture, Edge Cases).

### Q3: `_AXUIElementGetWindow` through `dlsym`, with safeguards (owner decision 2026-11-09)

The window number of an `AXUIElement` has no public API. The plugin resolves the private symbol
`_AXUIElementGetWindow` with `dlsym` at runtime (never linked), checks the result for nil, and at start-up calls it
once on a known window and compares the answer with `CGWindowList`. A missing symbol or a mismatch makes the
client's `availability` `.unsupported(reason)`; `activate()` throws and the plugin goes to `failed` with a banner.
There is no fallback in v1: the failure mode is a disabled feature, never a crash or parked windows.

## Measurements to take (all not yet measured)

Run on macOS 26 and macOS 27, Apple silicon, with the owner's usual apps (include one Electron app and one app
that is hung on purpose, for example a process stopped with `kill -STOP`).

| # | Question | Result |
|---|---|---|
| 1 | How far can a window be parked: the largest offset macOS 26 accepts for `kAXPositionAttribute` (does it clamp to the display, keep a sliver, or refuse) | not yet measured |
| 2 | Same on macOS 27 | not yet measured |
| 3 | The smallest visible sliver macOS leaves of a parked window, and whether it is clickable | not yet measured |
| 4 | Cost of 20 `setFrame` calls (position + size) across 5 apps, serial and parallel per app, median and p95 | not yet measured |
| 5 | The order that moves a window across displays reliably (size, position, size) and the failure rate of the other orders | not yet measured |
| 6 | Accessibility latency against a hung app with `AXUIElementSetMessagingTimeout` at 0.25 s: does the call return within the timeout, and does it block other apps' calls | not yet measured |
| 7 | `dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow")` resolves on macOS 26 and 27 and agrees with `CGWindowList` for 20 windows | not yet measured |
| 8 | The real preference keys and values behind Stage Manager (`com.apple.WindowManager` `GloballyEnabled` is the spec's inference) | not yet measured |
| 9 | The real key behind "Displays have separate Spaces" (`com.apple.spaces` `spans-displays` is the spec's inference) and which value the plugin requires | not yet measured |
| 10 | Frame rounding: does a set frame read back equal on Retina displays, and the tolerance the echo suppression needs | not yet measured |

## Until the measurements exist

The implementation uses the spec's working assumptions, each behind one constant so the measured value replaces it
without a design change: the parking offset is "the bottom-right corner of the bounding box of all displays minus a 1 point sliver" (the corner of one display could touch a neighbouring display; still not measured) in the pure
workspace code, the echo tolerance is 2 points, the per-app timeout is 0.25 s, and the Stage Manager and Spaces keys
are read with the names above and treated as "unknown" (no banner) when absent. Each of these is listed in
`docs/qa.md` as a manual item when step 1.12 lands.

## Go / no-go

**Go for the implementation** (the decisions are the owner's). **No-go for registering the plugin** (step 1.12)
until rows 1, 5, 6 and 7 are measured on a real Mac and written above.

## Addendum (architecture review rounds 1 and 2): where ordering and merging live

Events and ordering were handled in three places (the client's buffer, the stream's own bound and the engine's
coalescer), each merging or dropping on its own. The decision:

- **One coalescer.** `EventCoalescer` in the engine is the only place events are merged (one pending event per kind
  and window, a destroyed window drops its other events, overflow becomes one `.spaceChanged`). `AXEventBuffer` only
  bounds the stream (`bufferingNewest`) and, when it overflows, queues a `.resync` behind the lost events, so a
  dropped `.destroyed` or `.focused` is recovered by a full look instead of being lost silently. The 30 ms tick
  exists once, in the engine.
- **Ordering exists once per process.** Frame changes and focus for one app go on that app's lane in `LaneScheduler`
  (the engine's executor); `AXWindowClient` keeps its own per-process serial queue only because Accessibility
  elements are valid only on the queue that created them. The two are different guarantees (command order versus
  element confinement), not two copies of one.
- **The flush is serial and subscription comes first.** One flush loop, a flush strictly after the previous one, and
  `WindowClient.subscribe()` before the first snapshot, so no change between the two is lost and no stale move can
  follow a destroy.
- **Layouts are open.** `LayoutKind` is an identifier, strategies own their state, configuration and commands, and
  `state.json` stores each kind's state as opaque JSON under its name (shape unchanged).
