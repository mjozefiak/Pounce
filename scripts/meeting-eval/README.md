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
