# Execution plan: DICT-0.3, ADR 0010 (dictation context)

- Date: 2026-11-19
- Branch: `feat/dict-0-3-adr-0010-dictation-context`
- Source doc: `.ai/specs/backlog/2026-11-13-epic-context-aware-dictation.md` (story DICT-0.3)
- Owner decisions applied: 2026-11-19, numbers 6 and 7 (in the repository through PR #104, not merged when this
  run started)

## Goal

One document a reviewer can check every later DICT pull request against: the trust model, the frozen shape of the
`LintelKit` port, the budgets, and a fixed set of reference phrases.

## Scope

- `docs/decisions/0010-dictation-context.md`, status Proposed (Accepted only after the owner accepts it in the PR).
- `docs/perf.md`: new budget rows with an empty "Measured" column.
- `Tests/DictationPluginTests/Fixtures/context/reference-phrases.json` (at least 60 synthetic phrases, PL and EN)
  and one Swift Testing test of the file's format.

## Non-goals

- No change in `Sources/`, `Package.swift`, `LintelKit` or `BACKWARD_COMPATIBILITY.md` (those belong to DICT-2.1 and
  later stories).
- No results of the DICT-0.2 probes: they have not been run. Every point that depends on them is marked
  "to be confirmed by the DICT-0.2 probe" and carries no number.
- No baseline numbers for DICT-0.1: the owner passed the gate without a count.
- No change of `CleanupPrompt` or `FormatterGuard` (decision 7 is implemented by its own story; this ADR only
  states the rules that work must keep).
- No edits to the backlog files: PR #104 already carries the 2026-11-19 annotations for the same lines.
- No text from real meetings or dictations.

## Risks

- The contract is frozen before the DICT-0.2 probes. The ADR lists what may still change and says that DICT-2.1
  must not start on those points before the probes.
- No baseline exists, so the epic's "halve the corrections" metric has nothing to compare against. Recorded in
  the ADR as an accepted risk with the replacement measurement.
- `0010` could be taken by a parallel PR. Checked on `origin/main` and in the open PRs on 2026-11-19: free.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: ADR

- [ ] 1.1 Write ADR 0010 (trust model, frozen contract, owner decisions, open points)

### Phase 2: Budgets and phrases

- [ ] 2.1 Add the budget rows to docs/perf.md
- [ ] 2.2 Add the reference phrases and the format test

### Phase 3: Validation

- [ ] 3.1 Run the validation gate and the review pass
