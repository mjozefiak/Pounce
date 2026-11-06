# Deterministic flaky tests

Goal: make `ChooseFolderRaceTests`, `theSeedWaitsForTheFirstFinishedScan` and the time-dependent `Index controller` tests stable, by injecting control instead of waiting on the clock or a real system.

Non-goals: raising timeouts, retries, weaker assertions, `.disabled`, production behaviour changes.

## Progress

> Convention: `- [ ]` pending, `- [x]` done.

### Phase 1: Fix by cause

- [x] 1.1 ChooseFolderRaceTests: injectable folder check held on a latch
- [x] 1.2 theSeedWaitsForTheFirstFinishedScan: scripted Spotlight source
- [x] 1.3 Index controller: reproduce (10 plain, 20 loaded, 15 TSan loaded runs: no failure); left unchanged
- [x] 1.4 Full gate, TSan on PluginHost, Files, Meetings
