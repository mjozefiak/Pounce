# scripts/meeting-eval

Offline tools for judging meeting quality. Not part of the build gate or CI. Python 3, standard library only; run with `python3 -I`.

Run the tests of this folder with `python3 -m unittest discover scripts/meeting-eval` and paste the result into the PR.

## Gold set (MEET-1.3)

The gold set is a small collection of real meetings with hand-checked truth. It holds voices and conversation content, so **it never lives in this repository or in a tracker**. The repository contains only the format and the validator; progress is reported as a count ("3 entries pass the validator").

### Where it lives

On an encrypted disk image owned by the user. Point the tools at it with:

```sh
export LINTEL_MEETING_GOLD_DIR=/Volumes/<encrypted image>/meeting-gold
python3 -I scripts/meeting-eval/validate_gold.py            # validates every entry under the directory
python3 -I scripts/meeting-eval/validate_gold.py <dir|entry.json> ...
python3 -I scripts/meeting-eval/validate_gold.py --no-audio-check ...   # skip the audio file check
```

Exit codes: 0 all valid, 1 some invalid, 2 usage or input error. Output has entry ids, field paths and counts only, never text.

### Layout

```
$LINTEL_MEETING_GOLD_DIR/
  <entry id>/
    entry.json
    mic.wav        # file names are set in entry.json "audio"
    system.wav
```

The two WAV files are the decrypted two-track audio of the recording. They are produced from the encrypted spool by a tool kept outside the repository, run by hand by the owner (it triggers a Keychain prompt, decision M-Q17). The plain files exist only on the encrypted image and are deleted together with the entry.

### `entry.json` (schema 1)

| Field | Type | Rule |
|---|---|---|
| `schema` | number | `1` |
| `id` | text | `[a-z0-9][a-z0-9_-]*`, at most 64; same as the folder name |
| `language` | text | `pl` or `en` |
| `audio` | object | `mic` and `system`: plain file names in the entry folder, files must exist |
| `speakers` | list | at least 1; each `{id, name, track?}` (`track` is `mic` or `system`); ids unique |
| `transcript` | list | at least 1 segment `{speaker, start, end, text}`; `speaker` is a speaker id; times in seconds, `end >= start`; the text is the corrected transcript |
| `english_terms` | list of text | English terms said in the meeting; the list may be empty, the field is required |
| `key_points` | list | 10 to 25 items `{id, text}`; item ids are unique within the list (also for `decisions` and `tasks`) |
| `decisions` | list | items `{id, text}`; may be empty |
| `tasks` | list | at least 1; each `{id, text, owner, due}`; `owner` is a speaker name; `due` is `YYYY-MM-DD` or `null` |
| `consent` | object | `participants_agreed` (bool) and `cloud_judges` (bool): `true` only when the participants agreed to cloud judges (so it needs `participants_agreed: true`); tools must not send the meeting to a non-local judge otherwise |

A missing or invalid field is reported as `<field path>: <reason>`, for example `tasks: missing` or `tasks[0].owner: missing`.

### Dataset target

Three meetings from dogfooding, at least two in Polish and at least one with English terms. Each must pass the validator before the baseline (MEET-1.5) is measured.

## Note metrics (MEET-1.4, part 1)

`score_notes.py` measures notes against a gold entry with code, not a judge. Output is numbers and meeting ids only.

```sh
python3 -I scripts/meeting-eval/score_notes.py score --gold <entry.json> --notes <notes.json> [--out scored.json]
python3 -I scripts/meeting-eval/score_notes.py compare --baseline <runs.json> --candidate <runs.json> --metric coverage
```

`notes.json` (schema 1): `{"schema": 1, "meeting": "<id>", "points": [{"kind": "summary|key_point|decision|task|question", "text", "owner", "due", "quote": {"text", "time"} | null}]}`. `owner` and `due` belong to tasks. A `meeting` that differs from the gold entry's `id` is refused; malformed fields exit with code 2 and the field path only.

| Metric | Meaning |
|---|---|
| `coverage` | gold key points and decisions matched one-to-one by a note point (questions never match) |
| `quoteConfirmedShare` | note points (not questions) whose quote occurs, token for token, inside one gold transcript segment |
| `taskF1` | gold tasks vs note tasks matched by text; level `task` = the match, `owner` = and the same owner, `due` = and the same owner and due |

Matching is lexical (Dice over the Polish-normalized tokens of `score.py`, threshold 0.5): a deterministic proxy. It is a maximum-cardinality one-to-one assignment (ties: higher total similarity, then index order), not greedy. Every function takes a `similarity` argument, so the judge panel (part 2) plugs a semantic matcher into the same seam.

`compare` takes two JSON lists of runs (each run `{meeting id: score result}`), at least 3 per variant, paired on the same meetings. It says `above-noise` only when the mean paired difference exceeds the measured run-to-run spread (the larger standard deviation of the two variants, averaged over meetings); otherwise `within-noise`, or `insufficient-runs`.

`require_local_judge(entry, judge_is_local)` raises `ConsentError` for a non-local judge unless the entry has `participants_agreed` and `cloud_judges` both true.

## Judge panel (MEET-1.4, part 2)

`judge_panel.py` decides semantic matches with 2-3 local judges from different model families and plugs into the `similarity` seam of `score_notes.py`. A candidate pair (lexical Dice >= 0.15; below it nobody is asked) gets one vote per judge; unanimous = decided; otherwise the pair is disputed and every judge votes until it has at least 5 votes (`repeats`), and the pair matches when more than half of all votes say yes. The report gives the number of pairs asked and disputed, judge calls and the spread between repeats (standard deviation of the per-repeat share of yes votes, mean and max). Protocol and prompt: `notes-rubric.md` section 6.

```sh
python3 -I scripts/meeting-eval/judge_panel.py score --gold <entry.json> --notes <notes.json> --judges <judges.json> [--out scored.json]
```

`judges.json` (or the path in `$LINTEL_MEETING_EVAL_JUDGES`): `{"repeats": 5, "candidate_floor": 0.15, "judges": [{"name", "family", "local": true, "argv": ["..."], "timeout": 300}]}`. `candidate_floor` (0..1, default 0.15) is the lexical floor below which nobody is asked; 0 asks every pair, which costs more calls but also reaches paraphrases with no shared words. A judge is a command started without a shell; the prompt goes to stdin and it answers `{"match": true|false}`. `local` is the operator's declaration. Before any call, every judge goes through `require_local_judge`: a non-local judge on an entry without `participants_agreed` and `cloud_judges` ends with exit code 3 and no judge is called. Output has ids, judge names, families and numbers only. Tests use a scripted fake judge; the real-model test is skipped unless `$LINTEL_MEETING_EVAL_JUDGES` is set.
