# Notes quality follow-ups to #120 (issue #142)

Goal: fix the four quality gaps found after #120 (prompt v5): partial REDUCE, fallback pick, task dedup, context-free questions, verdictless reports. Prompt v6.
Non-goals: P1 (Claude path, fact guard). No meeting content anywhere; fixtures synthetic.
Source doc: issue #142

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Find the cause and fix REDUCE fallback

- [x] 1.1 Diagnose why REDUCE ends partial (trace, timeout/maxTokens/parse) and fix or document
- [x] 1.2 Fallback pick spreads over the whole meeting (tests)

### Phase 2: Tasks, questions, reports

- [x] 2.1 Task dedup and non-work task filter (tests)
- [x] 2.2 Drop context-free open questions (tests)
- [x] 2.3 Reports: verdict or drop (tests)

### Phase 3: Prompt v6 and measurement

- [x] 3.1 Prompt v6 + snapshots (+ en/pl strings if touched)
- [x] 3.2 N-run stability measurement on synthetic input, before/after table

## Notes

- 1.1 Cause found by reading the code, not reproduced on a real model (no model in this session; real-meeting runs were not required): `complete()` retried a cut-off REDUCE with the SAME prompt and a doubled limit, and decoding is greedy, so a looping answer loops again until `.failed`, which `reduceSingle` turns into `codeOrder` and `partial`. Fix: the retry after a cut-off also adds the format reminder, so the prompt changes. A noise answer still ends `partial` (stability table: 10/20 -> 2/20 partial). `NotesTrace` attempts (`truncated`, `malformed`, `timedOut`) show which of the three happened on a real run.
- Measurement: `Tests/MeetingsPluginTests/Notes/NotesStabilityTests.swift`; numbers in the PR body and the scratchpad `stability.md`.
