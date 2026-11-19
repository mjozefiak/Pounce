# Synthetic example for the Fable judge

Everything here is invented: the meeting, the people, the client, the ids, the dates and the numbers. No real meeting or dictation was used. The files show the input and output formats of `../../fable-judge.md` and feed `../../test_validate_judge_result.py`.

| File | What it is |
|---|---|
| `segments.jsonl`, `speakers.json`, `meta.json`, `notes.md` | the input of one evaluation in the shape `meeting-export` 1 writes it: compact JSON with sorted keys, `is_self` as 0/1, `notes.md` with the `# <title>` header the export puts before the notes (the judge tool drops it, section 2 of the protocol), no trailing newline. `meta.json` holds only some of the meeting columns; a real export has all of them (listed in `meeting_columns`). There are no audio files. |
| `notes-trap.md` | the same note with planted errors: a changed number, an invented task, a removed task, a timestamp and an author marker |
| `trap-expected.json` | what the judge must report for `notes-trap.md` (section 9 of the protocol) |
| `result.example.json`, `result-trap.example.json` | hand-written answers in the result schema; they are illustrations, not the output of a judge run |
