# Execution plan: keep the shown workspace across a display reconnect

Goal: after sleep or a cable out and in, the display shows the workspace it showed before and parked windows are not left unmanaged.
Scope: `VirtualWorkspaceModel` (remember per display), reducer (ignore empty display list, reset rehides on display change), diagnostics counters. Non-goals: wake notifications (`AXObservationHub`, another PR), PR #70 areas.
Risks: shares `EngineTypes.swift` (`EngineDiagnostics`), `WindowsDiagnostics.swift` and `ReducerContext+Windows.swift` with PR #70; trivial conflicts expected.

## Progress

> Convention: `- [ ]` pending, `- [x]` done.

### Phase 1: model, reducer, diagnostics

- [x] 1.1 Red tests (model and reducer)
- [x] 1.2 Model remembers removed displays
- [x] 1.3 Reducer ignores empty lists, resets rehides, counters and diagnostics lines
- [x] 1.4 Spec addendum
