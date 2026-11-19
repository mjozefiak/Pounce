# Windows after wake: display-flap settle guard and diagnostics

## Goal
Stop OS-induced window changes during the display flap after wake from being adopted as user resizes, and make the wake sequence observable.

## Evidence
Logs (process Lintel, 2026-11-18/19, build with #95-#99): on wakes at 16:04, 08:14 and 10:53 a fallback 1920x1080 display becomes active ~8 s after DidWake while the 5120x1440 display disappears; the real display returns ~1.7 s later. Two wakes had no flap. Nothing is logged in category `windows`, so engine behaviour is unobserved.
Code: `adoptUserResize` (#95) adopts any non-echo size change of a tiled window and persists new weights.

## Scope
1. `displaySettleUntil` (memory only, engine clock): set to now + 3 s when the display list changes (also an empty list); `adoptUserResize` refuses while it runs.
2. Diagnostics counters and `os.Logger` lines (no titles, no app names) for display changes, and for system notifications in `AXObservationHub`.
3. Tests with explicit engine `now` values only.

Non-goals: debouncing display events, new settings, real-clock tests.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Settle guard

- [ ] 1.1 Settle window in state, set on display change, honoured by adoptUserResize
- [ ] 1.2 Tests with explicit `now`

### Phase 2: Diagnostics

- [ ] 2.1 Counters and diagnostics text
- [ ] 2.2 Logger lines in engine and AXObservationHub
