# Execution plan: MEET-1.2 harness metrics (transcript and speakers)

Source doc: .ai/specs/backlog/2026-11-13-epic-meeting-notes-beyond-claude.md (story MEET-1.2)

## Goal
Deterministic, code-computed meeting metrics in `scripts/meeting-eval/score.py`: one Polish normalizer and WER, English-term error, wrong-speaker word share, mixed segments, cluster difference, optional cpWER (MeetEval).

## Scope
`scripts/meeting-eval/` (score.py, test_score.py), `Tests/MeetingsPluginTests/Eval/` (additive `words` on `EvalResult.Segment`), tick step 1.3 in the speaker-quality spec. No changes in `Sources/`.

## Non-goals
NotesPipeline, NotesGuard, NotesComposer, NotesPrompt, TranscriptChunker, segment writes (dogfood in progress).

## Risks
Number folding changes existing WER slightly for texts with spelled numbers (intended). MeetEval API is moving: calls are guarded and the row is skipped on failure.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Metrics
- [x] 1.1 Polish normalizer and number folding
- [x] 1.2 English-term error, speaker metrics, cpWER
- [x] 1.3 Python tests on synthetic pairs
- [x] 1.4 Swift `words` field and test; spec step 1.3 ticked
