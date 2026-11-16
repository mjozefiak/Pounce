# Execution plan: MEET-1.4 part 1, deterministic claim-level note metrics

Source doc: .ai/specs/backlog/2026-11-13-epic-meeting-notes-beyond-claude.md (story MEET-1.4)
Engine: om-auto-create-pr (steps: 5, --loop: no)

## Goal

First of two allowed PRs for MEET-1.4: deterministic, code-computed metrics of meeting notes against a gold entry (MEET-1.3 schema), plus paired multi-run comparison with a noise rule and the cloud-judge consent gate. The LLM judge panel is part 2.

## Scope

- `scripts/meeting-eval/score_notes.py` (stdlib only; reuses the one Polish normalizer from `score.py`), `test_score_notes.py`, README section.
- Note input format `notes.json` (schema 1): points with kind, text, owner, due, quote. Metrics: gold-point coverage (key points + decisions), quote-confirmed share, task F1 at three levels (task; + owner; + due). Matching goes through an injectable matcher; the default is a deterministic lexical one, so part 2 plugs the judge panel into the same seam.
- Paired comparison: same meetings, >= 3 runs per variant, "above noise" only when the mean paired difference exceeds the measured run-to-run spread.
- `require_local_judge(entry, judge_is_local)` refuses a non-local judge without cloud consent.

## Non-goals (left for part 2)

- Judge panel (2-3 local judges, >= 5 repeats on disputed decisions, spread report), judge protocol and wiring of `notes-rubric.md`.
- Anything in `Sources/` (NotesPipeline, NotesGuard, NotesComposer, NotesPrompt, TranscriptChunker, segment writes). No real meeting content; synthetic fixtures only.

## Risks

- Lexical matching is a proxy for semantic matching; reported as such. README sections shared with MEET-1.2/1.3 stay separate.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: metrics

- [ ] 1.1 score_notes.py: note schema, matcher seam, coverage, quote share, task F1 levels
- [ ] 1.2 Paired comparison with noise rule and consent gate
- [ ] 1.3 Tests on hand-computed synthetic fixtures
- [ ] 1.4 README section
- [ ] 1.5 Gate and unittest output in PR body
