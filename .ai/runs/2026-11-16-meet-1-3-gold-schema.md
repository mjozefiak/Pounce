# Execution plan: MEET-1.3, gold set schema and validator

Source doc: .ai/specs/backlog/2026-11-13-epic-meeting-notes-beyond-claude.md (story MEET-1.3)
Engine: om-auto-create-pr (steps: 4, --loop: no)

## Goal

First PR of MEET-1.3: the entry format of the meeting gold set and a validator, so MEET-1.4 can score notes against it. No meeting data in the repo (M-Q17).

## Scope

- `scripts/meeting-eval/validate_gold.py` (stdlib only), `test_validate_gold.py`, `README.md`.

## Non-goals

- Gold data, the audio decrypt tool, `score.py` and metrics (MEET-1.2), anything in `Sources/` (NotesPipeline, NotesGuard, NotesComposer, NotesPrompt, TranscriptChunker).

## Risks

- README.md may also be touched by MEET-1.2; keep the sections separate.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: schema and validator

- [ ] 1.1 Validator and entry schema
- [ ] 1.2 Tests (one valid, three invalid entries, more)
- [ ] 1.3 README with LINTEL_MEETING_GOLD_DIR
- [ ] 1.4 Gate and unittest output in PR body
