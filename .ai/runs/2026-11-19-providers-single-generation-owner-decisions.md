# Execution plan: providers spec after the notes review (Q8 overturned), ADR 0010 Accepted, backlog edits

## Goal

Record three owner decisions of 2026-11-19 in the design documents. Docs only: no code, no behaviour or
appearance change.

## Scope

1. `.ai/specs/2026-11-10-external-ai-providers.md`: Q8 ("the same pipeline in v1") is overturned. The provider
   track becomes one generation from the whole transcript, with a new versioned prompt and a fact guard for
   text the model writes (P1). This is the condition that makes the providers feature worth building. The
   notes generation port, the transcript size limits, the "what leaves the Mac" list, the consent window, the
   tests and the PR split are redesigned around it.
2. `docs/decisions/0010-dictation-context.md`: Proposed becomes Accepted; `FieldKind` as an open set is
   accepted.
3. Backlog: the DICT-4.2 story text (decision 7 is `CleanupPrompt` version 2, the term list is a later prompt
   version) and three more clarifications of 2026-11-19 in the overview (Q8 overturned and P1, ADR 0010
   Accepted, B2/B3 on hold).

## Non-goals

- No Swift code, no tests, no strings.
- The local track repair (P0) is another agent's PR; it is named as a dependency and not described.
- No meeting content, quote or example from a real meeting enters the repository. Only design conclusions.
- Files owned by the mic-fix, wm-sleep and notes-format agents are not touched.

## Risks

- The spec is long and many sections name chunks; a missed sentence would contradict the new track. A final
  search for the old terms is a step of its own.
- The size limits are working values until the PR 1 measurement; the spec must say so.

## Progress

PR: #122

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Providers spec

- [x] 1.1 Decisions, status, TLDR and the questions table (Q8 overturned) — a71c212
- [x] 1.2 Architecture, port, size limits, what leaves the Mac, consent window, edge cases — a71c212
- [x] 1.3 Tests, matrix wording, risks, phasing and the PR split — a71c212
- [x] 1.4 Search for leftovers of the chunk track — a71c212

### Phase 2: ADR 0010 and backlog

- [x] 2.1 ADR 0010 Accepted, FieldKind accepted — db459da
- [x] 2.2 DICT-4.2 story text — 8393cc2
- [x] 2.3 Backlog overview clarifications — 50f156a
