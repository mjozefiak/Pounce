# Meetings: measurement procedure (story MEET-0.4)

This is a procedure for the owner. It records **no results**. The `Measured` columns of `docs/perf.md` stay
"not yet measured" until the owner has run the steps below and a later PR writes the numbers there. Story MEET-0.4
(`.ai/specs/backlog/2026-11-13-epic-meeting-notes-beyond-claude.md`) stays open until then.

Sources: the MEET-0.4 acceptance criteria, `docs/perf.md` (sections Meeting diarization, Meetings, Meeting notes),
`docs/qa.md` (Meetings audio sources, Meeting notes, Meetings: owner manual test plan) and step 1.12 of
`.ai/specs/2026-11-03-meeting-notes.md`.

## Rules

- **Privacy.** Recordings, transcripts, notes, speaker names and screenshots with meeting content never go into the
  repository, a PR or an issue. Only numbers and ids go there (the tables below). Keep the test audio on an encrypted
  disk image (like the gold set, `scripts/meeting-eval/README.md`) and delete it after the run. Get the consent of
  everyone on a real call before recording it.
- **Release builds only.** Debug timings and memory are not comparable. Do not use `--qa` for the soak and the real
  apps: `--qa` isolates the Keychain, and audio permissions belong to the app, not to a QA data folder
  (`docs/qa.md`, Meetings audio sources). Use the app from `scripts/make-app.sh` (no `CONFIGURATION=debug`).
- **Ad-hoc builds lose the System Audio Recording consent after every rebuild.** Build once, grant microphone and
  System Audio Recording, and do not rebuild between scenarios (or accept the prompt again and note it in the table).
- **Over budget is an issue, not a new budget.** Do not edit a budget, `DiarizationBudget.unmeasuredMaximumDuration`
  or a setting default to make a number pass. Open an issue with the number (acceptance criterion 4).
- **Name the machines.** Every table row names the Mac (`system_profiler SPHardwareDataType`: model, chip, memory),
  the macOS version (`sw_vers`) and the commit (`git rev-parse --short HEAD`). Measure on the owner's Mac and on the
  weakest Mac available (an 8 or 16 GB one is the one that matters for the notes).
- **No existing tool means a gap.** Gaps are collected in the last section; do not invent a number for them.

## 0. Setup

```sh
git rev-parse --short HEAD; sw_vers; sysctl -n hw.memsize; system_profiler SPHardwareDataType | grep -E "Model Name|Chip|Memory"
scripts/make-app.sh                 # release build, ad-hoc signed; dist/Lintel.app
open dist/Lintel.app                # then Settings: Meetings on, microphone and System Audio Recording granted
```

Models (Settings → Models, all downloaded by the app, nothing by hand): the speech model `parakeet-ultra`, the
diarization model `diarization-community-1` and the notes model (`Qwen3-4B-Instruct-2507-Q4_K_M.gguf`, 2.5 GB; the
30B-A3B file is 18.6 GB and only fits a large Mac). They live in `~/Library/Application Support/Lintel/Models/{speech,llm,diarization}/`;
list the exact folders with `ls`, the benchmarks below take those paths. Record the model file name and its SHA-256
(`shasum -a 256 <file>`; for the GGUF compare with the catalog in `Sources/LintelSpeech/ModelCatalog.swift`).

### Running one test suite in a release build

`docs/perf.md` and `docs/qa.md` say `swift test -c release --filter …`. `scripts/meeting-eval/run.sh` documents that
`swift test -c release` stops at a link error in `ClipboardPluginTests`, and builds the `MeetingsPluginTests` product
only. That file is the source of this recipe (read it, it is the working reference); the steps, run from the repository
root:

```sh
swift build -c release -Xswiftc -enable-testing --product MeetingsPluginTests
bundle="$(find .build -path '*Release/MeetingsPluginTests.xctest' -maxdepth 6 -print -quit)"
dev="$(xcode-select -p)"
helper="$dev/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
platform="$dev/Platforms/MacOSX.platform/Developer"
stage="$(mktemp -d)"; cp "$helper" "$stage/eval-runner"; ln -s "$PWD/$bundle" "$stage/eval.xctest"   # neutral names, see run.sh
# then, with the LINTEL_* variables of the section in front of it:
env DYLD_FRAMEWORK_PATH="$platform/Library/Frameworks" DYLD_LIBRARY_PATH="$platform/usr/lib" \
  /usr/bin/time -l "$stage/eval-runner" --test-bundle-path "$stage/eval.xctest/Contents/MacOS/MeetingsPluginTests" \
  --testing-library swift-testing --filter '<SuiteName>' 2>&1 | tee run.log
```

Where a section says "run the suite", use this recipe with its `--filter`. If plain `swift test -c release --filter …`
links on your machine, it is equivalent, but wrap it in `/usr/bin/time -l` yourself to get the peak (see the gap list,
item 3). Not run while writing this document: it was checked by reading the scripts and the tests only.

## 1. QA table: real apps and audio routes (criterion 1)

Run each scenario once with the app from section 0, with the System Audio Recording and microphone consent granted.
`docs/qa.md` ("Meetings audio sources", "Meetings: owner manual test plan" items 1, 3, 4) has the detail per item.

| # | Scenario | Do | Result |
|---|---|---|---|
| S1 | Zoom call (desktop app) | Join a call with one other person, both speak for 2 min. Start with ⌃⌥M, stop with ⌃⌥M. | |
| S2 | Google Meet (Chrome or Safari) | Same in a browser tab. Note the browser. | |
| S3 | Microsoft Teams | Same. | |
| S4 | Talk in a room | Microphone only, 2 people in the room, no call. System track is expected to stay silent ("Mówca 1" label when only the microphone spoke, `docs/perf.md`). | |
| S5 | Bluetooth headphones, one route | AirPods or another headset, a call, 2 min. | |
| S6 | Bluetooth A2DP → HFP switch | Headset connected, start playing audio (A2DP), start the recording, then open a call so the headset goes to HFP, speak on both sides; do it twice and once with the headset connecting while nothing plays (`docs/qa.md` Bluetooth item: the system track must continue within about a second, the gap is silent, the times of the two tracks stay aligned; check "Audio MIDI Setup" for no leftover "Lintel meeting tap" device afterwards). | |
| S7 | Speakers, no headphones | A call through the Mac speakers. The same sentence must not appear on both tracks (`EchoSuppressor`). Repeat once with `plugins.meetings.voiceProcessing` on (it is off by default; the spec asks the measurement for it, step 1.12). | |

Result codes: **both** = both tracks recorded and the transcript has both sides; **gap** = a track is missing audio
for part of the call (note the number of gaps and the total seconds from listening to the meeting window against the
clock); **error** = the recording did not start, stopped by itself, or a track never got audio (note the HUD message
or the log line). The meeting is judged by the owner reading the meeting window, not by anything this document stores.

Failure list (one row per failure; numbers and ids only, no transcript text, no names):

| Failure id | Scenario | Code (both / gap / error) | Seconds lost | Log category line (`Audio track … ended`, `Diarization …` without text) | Issue |
|---|---|---|---|---|---|
| | | | | | # |

To read the log lines (they carry no meeting text):

```sh
log show --last 30m --predicate 'subsystem == "com.lintelapp" AND category == "meetings"' --info
```

Each failure becomes an issue; the table links the issue number. The "Result" column of the scenario table is filled
with `both`, `gap (n, s)` or `error (id)`.

## 2. The 3 h recording (criterion 2)

One real recording to the automatic stop (the session ends by itself at 3 h with a countdown from 2 h 50 min,
`MeetingSessionLimits`). Use a long real call or a long talk plus a video playing through the speakers; both tracks
must carry speech, or the numbers do not represent the worst case. Disable sleep for the run (the app holds its own
sleep assertion, but keep the Mac on power). Free disk: at least 3 GB (the start guard is 1.5 GB, the stop guard 300 MB).

**Memory during the meeting (budget < 1.5 GB, Meetings row "Memory during a meeting"):**

```sh
pid=$(pgrep -x Lintel)
while true; do date +%H:%M:%S; footprint "$pid" | grep -iE "^Lintel|Footprint|phys_footprint"; sleep 300; done | tee footprint-3h.log
```

Run in a second terminal from the start of the recording. Take the largest `phys_footprint` value; also note the
value at 1 h and at 3 h. Same for **disk** (Meetings row "Disk for a 3 h meeting", at most about 700 MB):

```sh
du -sh ~/Library/Application\ Support/Lintel/Plugins/meetings/Spool     # every 30 min, then after "ready" (must be gone)
```

**CPU (< 15% of one core on average, row "Transcription while recording"):** over the first 30 minutes, then over the
whole run:

```sh
top -l 360 -s 5 -pid "$pid" -stats pid,cpu,mem | grep -E "^$pid" > cpu.log     # 30 min of 5 s samples; average the cpu column
```

Also compare the transcribed length with the elapsed time at Stop (the meeting window's last time vs the clock).

**Tail after Stop (budget < 3 s):** stop with ⌃⌥M at a moment someone is mid-sentence, with a screen recording
(QuickTime, or `screencapture -V`/⇧⌘5) running. The tail is the time from the key press to the HUD leaving
"finishing". Count frames in the recording and report seconds. Repeat for the 1 h meeting and for the 3 h one. Note that
the automatic stop at 3 h is a separate path; measure at least one manual Stop on a long meeting (2 h 50 min or more).

**Memory at rest after models are released (< 150 MB):** after the meeting is `ready` and the keep-warm time has passed
(60 s for the notes model, longer for speech if the setting is changed), `footprint "$pid"`.

**Diarization in the app after Stop.** Tracks longer than 90 minutes are not diarized (`DiarizationBudget`, the meeting
gets "Ja" / "Inni"). A 3 h meeting therefore will not be diarized in the app until the cap is changed (a code change
for a later story, based on section 3). Record in the table whether the "Ja / Inni" fallback banner appeared.

**Notes time of one hour (budget about 1 to 2 min on an M4 Max; aim 8 min or less on a weaker Mac):** this is section 4,
on the owner's Mac and on the weakest Mac, with the chosen notes model.

Results table (copy into the PR that records the numbers; one row per Mac and run):

| Mac (model, chip, memory) | macOS | Commit | Meeting length | Peak footprint (MB) | Footprint at 1 h / 3 h (MB) | Avg CPU, first 30 min / whole (%) | Spool size peak (MB), after ready | Tail after Stop (s) | Footprint at rest (MB) | Diarization (in app: ran / fallback) | Over budget (issue #) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| | | | 3 h | | | | | | | | |
| | | | 1 h | | | | | | | | |

## 3. Diarization benchmark (criterion 3)

`DiarizationBenchmarks` (`Tests/MeetingsPluginTests/Diarization/DiarizationBenchmarks.swift`, test
`diarizesARealRecording`). It is enabled by both variables and diarizes **one** 16 kHz mono WAV with
`maximumSamples: samples.count`, so it is not stopped by the 90 minute cap. It prints one line:

```
DIARIZATION: <minutes> min of audio in <s> s, <n> speakers, <n> spans, resident MB before/during/after: <a>/<b>/<c>
```

**Audio.** Four WAV files of one track: 60 min, 90 min, 120 min and 180 min, 16 kHz, mono, 16-bit PCM (or 32-bit
float). Convert a real recording with the built-in `afconvert`, and cut or extend it with Python's standard library:

```sh
afconvert -f WAVE -d LEI16@16000 -c 1 recording.m4a base.wav
python3 -I - base.wav 3600 60min.wav <<'PY'     # args: input, seconds, output; repeats the input when it is shorter
import sys, wave
src, secs, dst = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with wave.open(src) as r:
    p, data = r.getparams(), r.readframes(r.getnframes())
need = secs * p.framerate * p.sampwidth
data = (data * (need // len(data) + 1))[:need]
with wave.open(dst, "wb") as w:
    w.setparams(p); w.writeframes(data)
PY
```

Real, distinct audio is preferable. If a shorter recording is repeated to reach the length, write "looped" in the table:
the speaker count then means nothing, and memory and time are only a close estimate. Do not put these files in the
repository. The other track of a two-track meeting is a separate run (the app diarizes the tracks one at a time).

**Run** (section 0 recipe, `--filter 'DiarizationBenchmarks'`, once per length and per Mac, with the network off to
confirm nothing is fetched; the doc comment of the test asks for this):

```sh
export LINTEL_DIARIZATION_MODEL_FOLDER="$HOME/Library/Application Support/Lintel/Models/diarization/diarization-community-1"   # check with ls
export LINTEL_DIARIZATION_BENCH_AUDIO=/path/to/60min.wav        # then 90min.wav, 120min.wav, 180min.wav
# swift test (if it links) or the section 0 recipe, with /usr/bin/time -l in front
```

Take **time** from the `DIARIZATION:` line. Take **peak memory** from `/usr/bin/time -l` of the whole process
("peak memory footprint", bytes) and from the line's `during` value. The `during` value is read once after
the call returns, not a peak (see the gap list, item 3). Peak of the process also includes the test's own copy of the
audio (the whole WAV as `Data` and as `Float` samples, about 1 GB at 180 min), which the app does not hold (it keeps
`Int16`, 346 MB at 180 min). Record the audio buffer size next to the peak and say so in the table.

Results table (fills the Diarization row and the Diarization row of Meetings in `docs/perf.md`):

| Mac | Audio length | Looped? | Time (s) | Speakers | Peak footprint, `/usr/bin/time -l` (MB) | `during` (MB) | Audio held by the test (MB) | Result vs budget |
|---|---|---|---|---|---|---|---|---|
| | 60 min | | | | | | | |
| | 90 min | | | | | | | |
| | 120 min | | | | | | | |
| | 180 min | | | | | | | |

The Meetings row's expectation is about 30 to 60 s for 1 h and about 3 min for 3 h. The Diarization row has no budget
("not set"): the measurement sets it. If a length does not fit in memory or the machine starts swapping, write that
as the result; do not change `DiarizationBudget` in this story.

## 4. Meeting notes (criterion 2, Meeting notes section)

The tests are `RealNotesTests` (`Tests/MeetingsPluginTests/Notes/RealNotesTests.swift`): `theCorpusOnARealModel`
and `aLongMeetingOnARealModel`. They are off unless `LINTEL_NOTES_LLM_MODEL` is set. They print `NOTES-BENCH` lines
(no text) with `utterances`, `words`, `chunks`, `status`, `points`, `dropped`, `failedChunks`, `reduceFailed`,
`seconds` (the wall time of `NotesPipeline.run` including the model load), `footprintBeforeMB`, `footprintAfterMB`.

```sh
export LINTEL_NOTES_LLM_MODEL="$HOME/Library/Application Support/Lintel/Models/llm/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"   # check with ls
# One hour of speech: 20 repeats of the bundled long meeting (about 9 000 words), or a real transcript:
export LINTEL_NOTES_LONG_REPEAT=20
# export LINTEL_NOTES_TRANSCRIPT=/path/to/transcript.txt     # one "[mm:ss] Speaker: text" line per utterance
# suites: --filter RealNotesTests  (both tests), or  --filter 'RealNotesTests/aLongMeetingOnARealModel'
```

Per Mac and per model:

1. **Cold** run (right after a reboot or after `sudo purge`): `aLongMeetingOnARealModel`. Write down `seconds`, `chunks`.
2. **Warm** run: the same command again. Write down `seconds`.
3. **Corpus** once (`theCorpusOnARealModel`, five short cases): the lines go in the table as they are.
4. **Peak memory.** The test prints only the footprint before and after, not the peak. Run the section 0 recipe's
   `/usr/bin/time -l` (peak memory footprint of the whole run) and, in a second terminal,
   `while true; do footprint $(pgrep -f eval-runner) | grep -i "phys_footprint"; sleep 10; done` for a time series
   (`docs/perf.md` asks for a 10 s sample). Compare with a dictation-only run (context 4096) of the same model: this
   needs the app (Settings → Dictation, built-in formatting, dictate a paragraph, `footprint <pid>`).
5. **At rest after the notes.** In the app (not the test): write notes for a recorded meeting, wait 60 s, `footprint <pid>`.
6. **Dictation tail while notes run** and **waiting for a busy model**: in the app, see the rows of `docs/perf.md`;
   screen recording again, report seconds from the key release to the paste.
7. **Weakest Mac, 4B model only**, the 1 h case, and whether 8 min holds.

Budget check: Meetings acceptance criterion 2 asks "notes for one hour at most 8 min"; the `docs/perf.md` row says
about 1 to 2 min on an M4 Max, aim 8 min or less on a weaker Mac.

| Mac | Model file (SHA-256 first 12) | Case | chunks | Cold s | Warm s | status | points | dropped | failedChunks | reduceFailed | footprintBeforeMB | footprintAfterMB | Peak footprint (MB, `/usr/bin/time -l`) | Over 8 min (issue #) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| | | long x20 | | | | | | | | | | | | |
| | | corpus | | | (one row per case) | | | | | | | | | |

Quality of the notes (row "Quality of the notes", no figure promised): run `RealNotesTests` with
`LINTEL_NOTES_TRANSCRIPT` on three real Polish meetings, read the notes against the recording, and record only
counts: `dropped` and the number of points the owner marks as wrong. No text.

## 5. The remaining Meetings rows (criterion 4: no row may stay "not yet measured")

| `docs/perf.md` row | What to run | Tool |
|---|---|---|
| Shortcut to the visible HUD and both tracks started (< 300 ms) | 10 starts; screen recording, frames from key press to the HUD with both meters moving; report p50 and max. | screen recording; see the gap list, item 1 (the signposts the row names do not exist) |
| Transcription while recording (< 15% of one core; keeps up with real time) | Section 2, first 30 minutes of two-sided speech. | `top`, `sample Lintel 60` |
| Transcription tail after Stop (< 3 s) | Section 2. | screen recording; gap item 2 |
| Diarization after Stop | Section 3. | `DiarizationBenchmarks` |
| Memory during a meeting (< 1.5 GB) | Section 2. | `footprint` |
| Memory at rest after models are released (< 150 MB) | Section 2. | `footprint` |
| Disk for a 3 h meeting (about 700 MB) | Section 2. `--qa-meeting-spool-dir` with the two WAV options gives a repeatable disk check in a QA run (`docs/qa.md`: QA runs replay WAV files as the two tracks, no real capture). | `du -sh` |
| Library list: query and preview | Not measurable with an existing tool, see the gap list, item 4. | none |

## 6. Where each result goes in `docs/perf.md`

Done by a later PR once the tables above are filled. This PR leaves every `Measured` cell as it is.

| Result | Row in `docs/perf.md` |
|---|---|
| Section 3, all four lengths | "Meeting diarization": "Peak memory of offline diarization, one track" (time and peak per length, Status `Measured`), and the paragraph below it (cap, 3 h); Meetings: "Diarization after Stop" |
| Section 2 memory / CPU / disk / tail / rest | Meetings: "Memory during a meeting", "Transcription while recording", "Transcription tail after Stop", "Memory at rest after models are released", "Disk for a 3 h meeting" |
| Section 1 | Not in `perf.md`; the QA table goes into the PR body (criterion 1); a short note in `docs/qa.md` if a procedure changed |
| Section 4 | Meeting notes: "Notes for a 1 h meeting", "Peak memory with the 8192 context", "Memory at rest after the notes", "Dictation tail while notes are written", "Waiting for a busy model", "Quality of the notes"; tick the measurement checklist under the table |
| Section 5 | The remaining Meetings rows |

Also update, with the numbers: the "Nothing in this table has been measured yet" and "Not yet measured" paragraphs of
`docs/perf.md`, the 90 minute cap note in ADR 0007 (`docs/decisions/0007-meeting-spike.md`, "3 h diarization is NOT yet
measured", item 3) and `docs/qa.md` owner plan items 5 and 6. A figure above its budget is an issue, referenced from
the cell; the budget stays.

## 7. Gaps: what the existing tools cannot measure

1. **No signposts.** `docs/perf.md` (Meetings, "Shortcut to the visible HUD…") says "signposts of `MeetingController`".
   There are none: `grep -rn signpost Sources/MeetingsPlugin` finds nothing. The only logs are `Meeting recording
   started` / `ended` (`MeetingController`), `Meeting finished: <n> segments, <s> s` (`MeetingSession`), `Audio track
   <channel> ended` and the diarization lines (`MeetingFinalizer`). There is no log of the Stop key, of the first
   buffer of each track, or of the HUD leaving `finishing`. So start latency, per-track start and the tail after Stop are
   measured from a screen recording (frame counting), with a resolution of one frame (about 17 ms at 60 fps). Adding
   signposts is a code change and is not part of this story.
2. **"`MeetingFinalizer` logs the phase changes"** (same file, row "Transcription tail after Stop") is not what the code
   does (it logs the diarization steps only), see item 1.
3. **`DiarizationBenchmarks` does not record a peak.** It samples `resident_size` (`mach_task_basic_info`) before, once
   after the call and after `release()`. The `during` value is read after the work has finished. The peak must come
   from `/usr/bin/time -l` (peak memory footprint) around the whole process, which also counts the test's own audio
   copy (section 3), and it also cannot separate model load from clustering. `MeetingEvalTests` has a 250 ms
   `FootprintSampler` and reports `diarization.seconds` and `peakFootprintMB`
   (`scripts/meeting-eval/run.sh --audio … --diarization-folder …`), but it runs the speech engine first on the same
   audio in the same process, so its figure is not the diarization alone. Use it only as a cross-check.
4. **No benchmark for the library list** (row "Library list: query and preview"). No test seeds 1 000 meetings of
   1 000 segments, and no test times `libraryEntries`. The row cannot be filled with an existing tool; it needs a
   benchmark (a later story or a note that the row has no budget in the spec).
5. **No live memory peak for the app.** `footprint` every five minutes can miss a spike; the recorded values are
   samples, not a true peak. Say "sampled peak" in the table.
6. **No export of two-track audio for the benchmark.** The spool is encrypted and the plain two-track export is a tool
   kept outside the repository (`scripts/meeting-eval/README.md`, M-Q17); `DiarizationBenchmarks` wants a plain WAV.
   Use a recording that exists as a file (or the QA WAV options), not the spool of a real meeting.
7. **No automated gap count.** Gap detection in the transcript is a later story (MEET-1.7); until then the "gap" result
   of section 1 is from listening and the clock.
8. **`swift test -c release`** does not link here per `run.sh` and `docs/perf.md` (Windows plugin row); the recipe in
   section 0 is the workaround and has not been run while writing this document.
9. **Weakest Mac.** The repository cannot say which one it is; the owner names it in the table.
