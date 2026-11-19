# Synthetic example for the Fable judge

Everything here is invented: the meeting, the people, the client and the numbers. No real meeting or dictation was used. The files show the input and output formats of `../../fable-judge.md` and feed `../../test_validate_judge_result.py`.

| File | What it is |
|---|---|
| `segments.jsonl`, `meta.json`, `notes.md` | the input of one evaluation, as the export tool writes it |
| `notes-trap.md` | the same note with planted errors: a changed number, an invented task, a removed task, a timestamp and an author marker |
| `trap-expected.json` | what the judge must report for `notes-trap.md` (section 9 of the protocol) |
| `result.example.json`, `result-trap.example.json` | hand-written answers in the result schema; they are illustrations, not the output of a judge run |
