# Notes quality follow-ups to #120 (issue #142)

Goal: fix the four quality gaps found after #120 (prompt v5): partial REDUCE, fallback pick, task dedup, context-free questions, verdictless reports. Prompt v6.
Non-goals: P1 (Claude path, fact guard). No meeting content anywhere; fixtures synthetic.
Source doc: issue #142

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Find the cause and fix REDUCE fallback

- [ ] 1.1 Diagnose why REDUCE ends partial (trace, timeout/maxTokens/parse) and fix or document
- [ ] 1.2 Fallback pick spreads over the whole meeting (tests)

### Phase 2: Tasks, questions, reports

- [ ] 2.1 Task dedup and non-work task filter (tests)
- [ ] 2.2 Drop context-free open questions (tests)
- [ ] 2.3 Reports: verdict or drop (tests)

### Phase 3: Prompt v6 and measurement

- [ ] 3.1 Prompt v6 + snapshots (+ en/pl strings if touched)
- [ ] 3.2 N-run stability measurement on synthetic input, before/after table
