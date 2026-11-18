# Execution plan: MEET-1.4 part 2, local judge panel

Source doc: .ai/specs/backlog/2026-11-13-epic-meeting-notes-beyond-claude.md (story MEET-1.4)
Engine: om-auto-create-pr (steps: 5, --loop: no)

## Goal

Second PR of MEET-1.4: a panel of 2-3 local judges from different model families decides semantic matches between gold points and note points (criterion 2), disputed decisions are repeated at least 5 times and the spread between repeats is reported; `require_local_judge` runs before any judge call (criterion 4); the matching in `score_notes.py` becomes maximum one-to-one (#85).

## Scope

- `scripts/meeting-eval/judge_panel.py` (stdlib only), `test_judge_panel.py` with a scripted fake judge, README section.
- `notes-rubric.md`: new section with the claim-matching judge protocol and prompt (`match_protocol_version`), sections 1-5 and `rubric_version` unchanged.
- `score_notes.match_pairs`: maximum-cardinality assignment, ties by similarity then index (#85).
- Real local judge only behind `LINTEL_MEETING_EVAL_JUDGES` (config file path), off by default.

## Non-goals

- Anything in `Sources/` (M-Q4). No real meeting content (M-Q17); synthetic fixtures only. Cloud judges only for entries with consent, never default.

## Risks

- Judge noise is measured, not removed. A judge declared local in the config is trusted to be local; the tool cannot verify it.

## Progress

> Convention: `- [x]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: panel

- [x] 1.1 Maximum one-to-one matching in score_notes (#85) with a test where greedy differs
- [x] 1.2 judge_panel.py: judges, panel, disputed repeats, spread, consent gate
- [x] 1.3 Tests with a scripted fake judge; real judge test behind env var
- [x] 1.4 Judge protocol and prompt in notes-rubric.md; README section
- [x] 1.5 Gate and unittest output in PR body
