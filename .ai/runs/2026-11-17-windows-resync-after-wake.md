# Execution plan: resync windows after wake and display changes (F1)

Source doc: .ai/specs/2026-11-11-window-management-v2.md
Engine: om-auto-create-pr (steps: 4, --loop: no)

## Goal

After sleep or a display change the engine reads the real window frames again, so windows macOS moved while AX notifications were missed are re-placed (research section 2, hypothesis H3, fix F1).

## Scope

- `Sources/LintelApp/Ports/AXObservationHub.swift`, `AXEventBuffer.swift`: observe `didWake` and `screensDidWake`, a delayed second resync (~2 s, coalesced), every `.displaysChanged` followed by `.resync`; a pure notification-to-events table.
- Tests: table and delayed resync in `LintelAppTests`, engine test with `FakeWindowClient` in `WindowsPluginTests`.

## Non-goals

- F2 to F4 (model memory of removed displays, rehide cap, diagnostics), strip, resize. No `LintelKit` change.

## Risks

- Real wake behaviour needs the owner's Mac (manual plan, research steps 2-5).

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: resync

- [x] 1.1 Event table, delayed resync and hub wiring
- [x] 1.2 Unit tests (table, delayed resync) and engine test
- [x] 1.3 Spec addendum and gate
