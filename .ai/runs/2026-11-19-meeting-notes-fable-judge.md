# Execution plan: Fable judge protocol for meeting notes (B1)

Status: in-progress

## Goal

Add the versioned "Fable judge" protocol for judging the quality of meeting notes. It replaces the blind comparison (MEET-0.2) and the dogfood gate (MEET-0.3) by owner decision 2 of 2026-11-19 (recorded in PR #104).

## Scope

- `scripts/meeting-eval/fable-judge.md`: the protocol (purpose, input, rubric after decision 3, omission and fabrication categories, formatting, scale and thresholds, versioned judge prompt, privacy rules, repeatability, judge control, PR evidence, owner remarks).
- `scripts/meeting-eval/fable-judge-result.schema.json`: JSON Schema of one judge answer.
- `scripts/meeting-eval/validate_judge_result.py` with `test_validate_judge_result.py`: validator of the answer, the numbers-only public record, aggregation of runs and the trap check (standard library, same style as `validate_gold.py`).
- `scripts/meeting-eval/examples/fable-judge/`: a small synthetic meeting (invented), a clean note, a trap note and hand-written example answers.
- `scripts/meeting-eval/README.md`: a section that points to the above.

The layout follows the existing harness (MEET-1.2 to MEET-1.4 live in `scripts/meeting-eval/`; `docs/meetings-measurement.md` is the MEET-0.4 performance procedure and is not touched).

## Non-goals

- The tool that calls the judge (B2, kept outside the repository).
- Any change to Swift sources, to `notes-rubric.md`, `judge_panel.py` or the gold set format.
- Any real meeting or dictation content. Every example is invented.
- Any change to the participant-information text: by the owner's decision of 2026-11-19 it stays unchanged, does not mention the Fable judge or the cloud, and the first run on real meetings does not wait for the owner (recorded in `fable-judge.md` section 7 point 4 and section 11).

## Risks

- The thresholds are a first proposal without measured data; the protocol says so and versions them.

## Validation

Docs and offline Python only; no Swift code changes, so the Swift gate does not apply. Run `python3 -m unittest discover scripts/meeting-eval` and paste the result into the PR.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Protocol

- [x] 1.1 Protocol document and result schema — 1ee669b
- [x] 1.2 Synthetic example and trap note — 843cc3b

### Phase 2: Validator

- [x] 2.1 Result validator with tests — 6371411
- [x] 2.2 README section — b4ff33d
