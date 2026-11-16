# Performance measurements

Budgets from the MVP spec (`.ai/specs/2026-10-31-pounce-launcher-mvp.md`, Problem Statement and risk R6),
and what has been measured against them. Each row says where and how it was measured, so the next
measurement can be compared.

## Budgets (spec step 4.5, v1.0)

Machine for every row: Apple M4 Max, 16 cores, macOS 27.0.1, 2026-10-31. An M1 run is still to do.

| Budget | Target | Measured | Status |
|---|---|---|---|
| Panel open after the shortcut | < 50 ms | 12.1–16.5 ms (5 cold launches, first open) | Met |
| App query | < 5 ms | p95 0.54 ms with 300 apps, p95 2.28 ms with 1 000 apps (max 2.78 ms) | Met |
| File query, p95, 1 million entries (step 3.2) | < 30 ms | p95 7.1 ms (p50 3.8 ms, max 7.3 ms), synthetic names; table below | Met |
| Memory at rest with an index of ~500 k files | < 150 MB for the whole app | 39 MB in the session that ran the first scan, 36 MB after launching from the saved index (510 k entries), with `MallocLargeCache=0` (below); without it 217 MB and 84 MB | Met |
| First scan of `~` | < 30 s | 1.6–1.9 s for 510 k entries of a synthetic tree on the SSD | Met on the synthetic tree; a real home folder is a manual item |
| Start from the saved index until ready | < 2 s | 0.19 s from process start to "Loaded 510020 index entries" | Met |
| Index memory per entry (R6) | about 100 B | 67–70 B (synthetic), 83 B (fixture tree, 204 k entries) | Met |
| Path mode query, folder of 1 000 entries (file path search spec) | p95 < 20 ms | p95 8.3 ms read cold, 11.4 ms while typing a filter (release build, SSD; `PathModeBenchmarks`) | Met |
| App suggestions query, empty panel (app suggestions spec, 2026-11-02) | < 5 ms (source budget 150 ms) | p95 0.51 ms with 300 apps, p95 2.22 ms with 1 000 apps, every app with activity (max 2.57 ms; release build; `AppBenchmarks/suggestApps`) | Met |
| One-time Spotlight seed of app activity (app suggestions spec, 2026-11-02) | in the background, no budget | 57 ms for the 43 apps in `/Applications` of the measurement Mac, 24 of them with used dates (`AppBenchmarks/seedFromSpotlight`, reads real Spotlight metadata, writes only to a temporary directory) | Measured |
| Typing in the Notes editor, p99, 50 000 characters (notes workspace spec step 4.1, budget proposed in ADR 0008 addendum 0.1) | < 8 ms | not yet measured in a real window (the `EditorBenchmarks` text path, below, is a part of it) | To be measured |
| Main window visible after a Dock click (main window spec, 2026-11-04) | < 200 ms | not yet measured | To be measured |
| Settings pane switch in the main window (main window spec, 2026-11-04) | < 100 ms | not yet measured | To be measured |
| Models pane first paint with downloads running (main window spec, 2026-11-04) | < 150 ms | not yet measured | To be measured |

### How the app-level rows were measured

The panel, memory and start-up rows come from the running app. QA mode keeps the run away from the
tester's data (`docs/qa.md`), and its launch arguments exist only in DEBUG builds, so the measurement
build is a release build with QA compiled in. It is never shipped:

```bash
# The fixture tree of fake names (5 000 folders × 100 files, 510 020 entries), generated once by the
# file benchmarks; any FileBenchmarks test creates it before it runs.
LINTEL_BENCHMARKS=1 LINTEL_BENCH_TREE=/tmp/lintel-p4-bench/tree LINTEL_BENCH_FOLDERS=5000 \
  swift test -c release -Xswiftc -enable-testing --filter FileBenchmarks/scanFixtureTree
swift build -c release -Xswiftc -DDEBUG --scratch-path /tmp/lintel-perf-build
BIN=/tmp/lintel-perf-build/out/Products/Release/Lintel
FIX=/tmp/lintel-p4-bench/tree
APP_FIXTURES=$(mktemp -d)   # an empty apps root; the app rows below use their own benchmark
COMMON=(--qa --qa-data-root /tmp/lintel-perf/data --qa-setting "plugins.files.qaHome=$FIX"
  --qa-setting "plugins.files.roots=$FIX" --qa-setting plugins.files.setupCompleted=true
  --qa-full-disk-access granted --qa-setting "plugins.apps.roots=$APP_FIXTURES"
  --qa-setting plugins.apps.spotlight=false --qa-spotlight off --qa-accessibility denied
  --qa-setting app.onboarding.shortcutCompleted=true)
/usr/bin/log stream --predicate 'subsystem == "com.lintelapp"' --info --style compact &
```

- **Panel open:** `$BIN "${COMMON[@]}" --qa-panel search --qa-query rep --qa-quit-after 3`, five times.
  The log line "Panel ordered front in … ms" is the `show panel` signpost interval in
  `PanelController.presentPanel` (positioning and `orderFront`). QA mode opens the panel right after
  launch, so each number is a cold first open; with the global shortcut, the hotkey callback only adds
  `PanelModel.show` before it.
- **First scan and memory after it:** an empty data root, `$BIN "${COMMON[@]}"`; the scan time is the log
  line "Scanned N entries" against "Started with 3 plugins". Memory is `footprint -p <pid>` 60 s after the
  scan.
- **Start from the saved index and memory at rest:** the same command again with the same data root.
  Ready is the log line "Loaded N index entries", measured from the moment the process was started.
  Memory is `footprint -p <pid>` 60 s later.
- **App query:** `Tests/AppsPluginTests/Benchmarks.swift`, 20 queries × 10 rounds through
  `AppSearchSource.search` with `limit: 50`:

  ```bash
  LINTEL_BENCHMARKS=1 swift test -c release -Xswiftc -enable-testing --filter AppBenchmarks
  ```

### Memory right after the first scan

Without help, the session that runs the first scan of 510 k entries stays at 199–222 MB, above the
budget, until Lintel restarts. `heap` shows only 54 MB of live allocations (48 MB of them the index
arrays). `vmmap -summary` shows the rest as freed memory the allocator keeps: "Malloc Large (empty)"
about 104 MB and "Malloc Small (empty)" about 41 MB, dirty. Most of it is libmalloc's cache of freed large
allocations. The scan frees many of them: folder listings, the array copies made while a batch is applied
and while the arrays grow, and the snapshot encoder's buffers. `malloc_zone_pressure_relief` returns 0 and
releases nothing on macOS 27.

**Mitigation (v1.0):** `Resources/Info.plist` sets `LSEnvironment` → `MallocLargeCache=0`. This turns that
cache off, so freed large blocks go back to the system right away. Launch Services applies
`LSEnvironment` to every launch it makes (Finder, Dock, Spotlight, `open`, the login item); a binary
started directly from a shell (`swift run`, `.build/…/Lintel`) does not get it. The apps Lintel opens do
not inherit it: they are launched through Launch Services with their own environment. Measured with the
procedure above, `MallocLargeCache=0` set the way Launch Services sets it:

| Session (510 020 entries) | Default allocator | `MallocLargeCache=0` |
|---|---|---|
| First scan, footprint 60 s after it | 217 MB | 39 MB |
| Launched from the saved index, 60 s later | 84 MB | 36 MB |
| `FileBenchmarks.scanFixtureTree`: scan / footprint change | 2.18–2.19 s / 121–133 MB | 2.09–2.12 s / 21–22 MB |
| `FileBenchmarks.searchOneMillionNames`: p95 | 6.1–7.3 ms | 6.7–7.2 ms |

Scan and search times do not change. A Launch Services launch was checked with a throwaway bundle: the
process sees `MallocLargeCache=0`. To measure without the setting, run the binary directly as above. To
measure with it, prefix the command with `MallocLargeCache=0`.

## File index (Phase 3)

### How it was measured

`Tests/FilesPluginTests/Benchmarks.swift`, off by default:

```bash
LINTEL_BENCHMARKS=1 swift test -c release -Xswiftc -enable-testing --filter FileBenchmarks
```

- **Search:** `syntheticStore(count: 1_000_000)` (the generator from the tests: ten words, six
  extensions, nested folders, one folder per 20 entries), then 20 queries × 5 rounds through
  `FileSearch.search` with `limit: 50`, the same call the search source makes. Queries cover exact
  words, acronyms (`pln`, `bgt`), multi-word queries, a single letter and a query with no match.
- **Scan:** a fixture tree of fake names generated under `/tmp/lintel-p3-bench/tree` (2,000 folders ×
  100 empty files in 20 areas, 204,020 entries), indexed by `IndexController` with the default
  exclusions, from an empty storage folder to the first complete snapshot.
- **Memory:** `NameStore.approximateBytes` (the capacity of every array in the store) and the change in
  the process's physical footprint (`task_vm_info.phys_footprint`, what Activity Monitor calls Memory)
  across building the index. The footprint change also counts allocator slack and the arrays' growth
  copies, so it is an upper bound for the index itself.

Machine: Apple M4 Max, 16 cores, macOS 27.0.1, release build, 2026-10-31. Re-measured after the byte
prefilter learned camel-case and digit word starts (the review fix); the earlier run gave p95 6.6 ms.

### Results

| Measurement | 1 M synthetic names | 204 k fixture entries |
|---|---|---|
| Index size (`approximateBytes`) | 67.5 MB | 16.2 MB |
| Bytes per entry | 70 | 83 |
| Process footprint change | 93.8 MB | 26.3 MB |
| Query p50 / p95 / max | 3.8 / 7.1 / 7.3 ms | – |
| First full scan, including the first snapshot save | – | 231 ms |
| Snapshot on disk (LZFSE) | – | 0.7 MB |
| Snapshot load | – | 20 ms |

The fixture's names repeat a lot, so its snapshot compresses far better than a real one would.

### What this means for a real home folder

At 70–85 B per entry the index of a typical home folder (300–800 k entries after the default
exclusions, R6) takes 25–70 MB, and 1.5 M entries about 125 MB, against the spec's estimate of 100 B
per entry. The app's other memory (AppKit, SwiftUI, GRDB, icons) comes on top; the < 150 MB budget is
for the whole process at rest.

The numbers above are the index at rest. While the index changes, memory briefly goes higher:

- Applying a batch (scan listings or FSEvents changes) copies the arrays once, because searches still
  hold the last published copy. Until the next publish (at most 400 ms during a scan), the index takes
  about twice its size. After the publish the two copies share storage again.
- Saving the snapshot (after the first scan, then at most every 10 minutes and on quit) adds the
  encoder's buffers: roughly 30 B per entry uncompressed, plus the compressed file. A compacted copy of
  the index is also made when nodes were removed.

So measure memory at rest (step 2 below), not while Settings → Files still shows indexing.

### Manual measurement on a real home folder

Agents never scan a real home folder (`docs/qa.md`). The owner measures it once on their Mac:

1. Build and run a release app (`scripts/make-app.sh`), allow Full Disk Access if wanted, finish the
   File Search step and wait until Settings → Files shows "N items indexed".
2. Wait a minute, then read Memory for Lintel in Activity Monitor (or
   `footprint -p $(pgrep -x Lintel)`).
3. Record here only the entry count, the memory and the machine. Never record paths or names.

Also still to do by the owner for v1.0, because an agent cannot do them:

- The time of the first scan of the real home folder (Settings → Files shows "Indexing…" until it
  ends; < 30 s).
- The whole budget table on an M1 Mac, the slowest supported machine.
- Opening the panel with the real global shortcut while another app is active (the QA run above opens
  it at launch and never registers a hotkey). Run
  `/usr/bin/log stream --predicate 'subsystem == "com.lintelapp"' --info` and press the shortcut ten
  times; read "Panel ordered front in … ms".

## Dictation (spec: Dyktowanie głosowe, Phase 1)

Budgets of the spec. Rows marked "manual" are measured on a real Mac with the downloaded model in step 1.9
and filled in then; nothing here is estimated.

| Budget | Target | Measured | Status |
|---|---|---|---|
| Shortcut to recording started and HUD visible | < 150 ms (the model need not be in memory; audio goes to a buffer) | – | Manual (1.9) |
| Parakeet Ultra cold load | < 3 s, in the background, without losing audio | – | Manual (1.9) |
| Raw text ready after a 5-minute recording | < 2 s | – | Manual (1.9) |
| Memory at rest (model unloaded) | unchanged, < 150 MB for the whole app | – | Manual (1.9) |
| Memory while dictating | measured, about 0.8–1.2 GB expected | – | Manual (1.9) |
| Whisper large-v3-turbo cold load | measured in step 1.10 | – | Manual (1.10) |

### Formatting (Phase 2)

| Budget | Target | Measured | Status |
|---|---|---|---|
| Formatted text ready after stopping, tail ≤ 60 words (Qwen3.6-35B-A3B 4-bit, M-series Max/Ultra) | < 3 s (ADR 0004) | – | Manual (QA with Ollama) |
| Same with a 4B model on a base M-series | < 8 s | – | Manual (QA with Ollama) |
| Built-in model (Qwen3-4B Q4_K_M) loaded while recording, ready before the user stops | < 3 s load on M-series (ADR 0005) | – | Manual (QA, step 4.4) |
| Resident memory with the built-in 4B model loaded / after keep-warm unload | ≈ 3.3 GB / back to the baseline | – | Manual (Activity Monitor) |
| Time of one chunk request | printed by `LINTEL_LLM_URL=… swift test --filter CleanupFixtureTests/realServer` | – | Manual |

Run the local integration tests with the model installed (they are off by default):

```sh
LINTEL_DICTATION_MODEL_FOLDER=~/Library/Application\ Support/Lintel/Models/speech/parakeet-ultra \
  swift test --filter RealModelTests
```

## Path mode (file path search)

A query that starts with `/` or `~` reads one folder from disk instead of the index
(`PathSearchSource`, `DirectoryLister`). `PathModeBenchmarks.thousandEntryFolder` lists a generated
folder of 1 000 entries 50 times with a new lister (nothing cached) and then types five filters ten
times each against a cached listing; run it with
`LINTEL_BENCHMARKS=1 swift test -c release --filter PathModeBenchmarks`.

- Typing is slower than the cold read because every keystroke runs `FuzzyMatcher` on each name; the
  folder itself is read only when its modification time changes.
- One folder is read up to 20 000 entries (`DirectoryLister.entryLimit`). A larger folder is cut, and the
  filter narrows within those entries; the shell shows 20 results per section.
- A slow volume (network share, sleeping disk) can exceed the 150 ms source budget; the host then drops
  the source's answer for that keystroke and the rest of the panel works.
- Folders are read on one serial queue (`DirectoryLister`), never on a Swift concurrency thread. A read
  that hangs (an unreachable network volume) makes later path queries time out until it returns;
  requests cancelled while waiting are skipped. Volumes mounted outside `/Volumes` are not treated as
  protected.

## Meeting diarization (spec: Notatki ze spotkań, step 1.6)

| Budget | Target | Measured | Status |
|---|---|---|---|
| Peak memory of offline diarization, one track | not set | **not measured** for 1 h, 90 min or 3 h (needs the model files and a real recording; `DiarizationBenchmarks`, `LINTEL_DIARIZATION_MODEL_FOLDER` + `LINTEL_DIARIZATION_BENCH_AUDIO`) | Open |

Until it is measured, `DiarizationBudget.unmeasuredMaximumDuration` caps a track at 90 minutes (the clustering
memory grows roughly with the square of the duration, not linearly). **3 h diarization is NOT yet measured**:
a track longer than the cap skips diarization and the meeting gets the channel labels ("Ja" / "Inni", or one
neutral "Mówca 1" when only the microphone spoke; `speaker_mode = channels`). Tighten or raise the cap after
the benchmark has run (ADR 0007).

## Meetings (spec: Notatki ze spotkań, budgets of Phase 1; measured in step 1.12)

Nothing in this table has been measured yet: it needs the speech and diarization models, a Mac with the system-audio
permission granted and real meetings, none of which `swift test` or a `--qa…` run can provide. The targets are the spec's.

| Budget | Target | Measured | How to measure |
|---|---|---|---|
| Shortcut to the visible HUD and both tracks started | < 300 ms | not yet measured | Build with `scripts/make-app.sh`, grant microphone and system audio, run `log stream --predicate 'subsystem == "com.lintelapp"'` and note the time between the `meetings.record` command and the first buffer of each track (signposts of `MeetingController`); 10 runs, report p50 and max. |
| Transcription while recording (both tracks, resident speech model) | keeps up with real time, < 15% of one core on average | not yet measured | Record 30 minutes of two-sided speech; in Activity Monitor sample the Lintel CPU every 5 s (or `sample Lintel 60`), and compare the transcribed length with the elapsed time at Stop. |
| Transcription tail after Stop | < 3 s | not yet measured | Stop in the middle of a sentence; measure from the command to the HUD leaving `finishing` (`MeetingFinalizer` logs the phase changes without text). |
| Diarization after Stop (1 h, two tracks, about 122x real time per the vendor) | about 30 to 60 s; 3 h about 3 min | not yet measured | `LINTEL_DIARIZATION_MODEL_FOLDER=… LINTEL_DIARIZATION_BENCH_AUDIO=… swift test --filter DiarizationBenchmarks -c release`, 1 h and 3 h audio, on the target and on a weaker Mac. |
| Memory during a meeting (speech model and buffers) | < 1.5 GB | not yet measured | Record 1 h; `footprint Lintel` (or Activity Monitor, Memory column) every 5 min; report the peak. Diarization has its own limit (section above). |
| Memory at rest after models are released | unchanged: < 150 MB | not yet measured | After the meeting is `ready` and the keep-warm time has passed, `footprint Lintel`. |
| Disk for a 3 h meeting | at most about 700 MB of spool, deleted once processed | not yet measured | Record 3 h; `du -sh ~/Library/Application\ Support/Lintel/Plugins/meetings/Spool` during and after (use `--qa-meeting-spool-dir` in a QA run with the WAV options for a repeatable check). |
| Library list: query and preview | no budget in the spec; the panel budget applies (a keystroke answers in a frame) | not yet measured | `--qa` run with a library of 1 000 meetings of 1 000 segments each; time `libraryEntries` for an empty and a two-word query (XCTest `measure` or `ContinuousClock` around the call). |

## Meeting notes (spec: Notatki ze spotkań, step 2.5)

**Not yet measured.** Nothing here has been run: it needs a downloaded GGUF model (`LLMModelCatalog`), real meeting
transcripts and, for the weaker-Mac rows, a second machine. The tests in `swift test` use a scripted model and prove
the logic, not the speed. The targets are the spec's; the numbers behind them are ADR 0005's (M4 Max: prefill about
1 000 tok/s, decode about 95 to 115 tok/s).

Configuration the measurements are made with (the values of the code; change a value only together with this table):

| Setting | Value | Where |
|---|---|---|
| Context length | 8192 (`LlamaRuntime(contextLength: 8192)`, a lease key of its own next to dictation's 4096) | `NotesModel.contextLength` |
| `plugins.meetings.notesChunkTokens` | 3 000 input tokens per MAP chunk (a few utterances of overlap) | `MeetingsSettings.defaultNotesChunkTokens` |
| `plugins.meetings.notesReduceInputTokens` | 4 500 input tokens per REDUCE request, one more level above that | `MeetingsSettings.defaultNotesReduceInputTokens` |
| Answer limits | 700 tokens (MAP), 1 500 tokens (REDUCE), a cut-off answer is retried once with double the limit | `NotesPipeline.Configuration` |
| Time limits | 300 s per MAP request, 600 s per REDUCE request (generation only); one retry; a busy model is waited for up to 30 min | `NotesPipeline.Configuration` |
| Sampling | greedy, the model's chat template, cancelled between two tokens | `LlamaRuntime` |

| Budget | Target | Measured | How to measure |
|---|---|---|---|
| Notes for a 1 h meeting (about 8 MAP chunks and a REDUCE; built-in Qwen3 30B-A3B or 4B) | about 1 to 2 min in the background on an M4 Max; a weaker Mac: to be measured, aim for 8 min or less | not yet measured | Release build. `LINTEL_NOTES_LLM_MODEL=<gguf> LINTEL_NOTES_LONG_REPEAT=20 swift test -c release --filter RealNotesTests` (20 repeats of the bundled long meeting are about 9 000 words, the volume of one hour of speech; or `LINTEL_NOTES_TRANSCRIPT=<file>` with a real transcript in the `[mm:ss] Speaker: text` format). Read the `NOTES-BENCH … seconds=` line: it is the wall time of `NotesPipeline.run` including the model load. Run each model twice (cold file cache, then warm) and on the target and on a weaker Mac; report both numbers and the chunk count. |
| Peak memory with the 8192 context | model residency (3.3 GB for the 4B, 18.9 GB for the 30B-A3B, ADR 0005) plus the KV cache and compute buffers of an 8192 context; not set separately | not yet measured | The same run: `footprintBeforeMB` and `footprintAfterMB` of the `NOTES-BENCH` line are `phys_footprint`; also sample `footprint <pid>` every 10 s during the run in a second terminal and report the peak. Compare with a dictation-only run (context 4096) of the same model. |
| Memory at rest after the notes | unchanged: < 150 MB | not yet measured | After the job, wait the keep-warm time (60 s for notes) and run `footprint <pid>` on the app. |
| Dictation tail while notes are written | the dictation budget plus one reload of the model at the dictation context (4096): the notes use another context length (8192), so the lease takes the model from the notes (the generation is cancelled between two tokens), unloads the 8192 copy and loads it again at 4096; aim for < 3 s warm file cache, measure the reload | not yet measured | In the app, with notes running on a long meeting, dictate a sentence with the built-in formatting; time from release of the key to the paste. Afterwards the notes reload at 8192 and repeat the interrupted request (one extra load of the model and one repeated MAP/REDUCE request per interruption). The notes do not take the model back at once: for 15 s after dictation's lease was released they wait ("Czeka na model"), so a second dictation in a row finds its model loaded; the waits of one notes job add up to a 30-minute budget and one request gives up after 20 takeovers (`modelBusy`). |
| Waiting for a busy model | notes wait ("Czeka na model") and then run; only a different model *file* in use causes this (the same file at another context length is taken over by dictation) | not yet measured | Start dictation with another formatting model file during a notes job (or the other way round) and watch the library badge. |
| Quality of the notes | no figure promised (`NotesGuard` limits invention, it does not remove errors) | not yet measured | `RealNotesTests` on the corpus and on three real meetings in Polish; record the dropped counts and read the notes against the recording. |

Measurement checklist (copy into the PR that records the numbers):

- [ ] Machine, macOS version, memory, build (`release`), model file and its SHA-256 (from the catalog).
- [ ] `NOTES-BENCH` lines of `theCorpusOnARealModel` (five short cases) and `aLongMeetingOnARealModel` (about 1 h).
- [ ] Cold and warm time for the 1 h case; chunk count; `status`, `dropped`, `failedChunks`, `reduceFailed`.
- [ ] Peak `footprint`, with and without the notes (dictation only), the same model.
- [ ] The weaker Mac (8 or 16 GB): the 4B model only, 1 h case, and whether the 8 minute aim holds.
- [ ] Dictation tail with a notes job running.
- [ ] If a figure differs from the table above by a large factor, change `notesChunkTokens` / `notesReduceInputTokens` here and in `MeetingsSettings`, and record why.

## Window management (spec `2026-11-09-window-management`)

| Budget | Target | Measured | How |
|---|---|---|---|
| Switch workspaces with 20 windows | < 100 ms on Apple silicon | not yet measured | 20 windows of 5 apps, `windows.workspace.2` and back; time from the key to the last `setFrame` returning. |
| Strip redraw after a switch | < 16 ms | not yet measured | Time from the engine summary to the new status item image. |
| Tiling reflow after one window event | < 30 ms | not yet measured | Phase 2 (step 2.4). 10 tiled windows of 5 apps, open or close one; time from the event reaching the engine to the last `setFrame` returning. Pure frame computation (`TilingLayout.frames`) is cheap by construction; the cost is the Accessibility calls, which need a real Mac. No benchmark exists yet. |
| Shift-drag overlay appears (notification-driven) | < 150 ms (owner decision 2026-11-10; was < 50 ms) | median 127 ms, p95 132 ms (QA pass 3, 2026-11-10, owner's machine, TextEdit); meets the new budget | Phase 3 (step 3.5b). Time from the first moved event of a dragged window (Shift held, button down) to the panels on screen. The panels are built when the plugin starts (`prewarm()`) and reused: measure the first and the tenth drag. Needs a real display; the benchmark below covers only the pure part. **QA on a real desktop (2026-11, owner's machine, 3 runs) measured about 145 ms** from the first moved event to the overlay on screen, so the budget was not met. Round 9 removed two known parts of it: the first move of a window on a workspace that offers snap targets is flushed at once instead of waiting for the 30 ms coalescing tick (`WindowEngine.ingest`, `DragLatencyTests`), and the overlay panels are built ahead of the first drag (`ZoneOverlayPanels.prewarm()`, called when the plugin starts). The savings have **not been measured on a real display**, the budget was then 50 ms and not met. A second QA pass on the build with both changes still measured about 122 ms (16 shift-drags: median 122.5, p95 130, min 113, max 132). There is **no dwell, threshold, animation or other intentional delay** on the path in the code (the drag machine only checks the cursor is on the moved window and Shift is down); round 11 removed the panel fade-in (`animationBehavior = .none`) and added a DEBUG per-stage trace (`plugins.windows.qaDragTrace`, `docs/qa.md`) so the next measurement can say where the remaining time goes. The cause of the rest was found in QA pass 3 (below). |
| Zones reflow after one window event | < 30 ms | not yet measured | Phase 3 (step 3.3). 10 windows of 5 apps in a 2×2 layout, open or close one; time from the event reaching the engine to the last `setFrame` returning. The Accessibility calls need a real Mac. |
| Layout editor opens | < 200 ms | not yet measured | Phase 4 (step 4.4). Time from *New layout* or *Edit…* (the click) to the editor sheet and the live preview panel on screen. The editor model, the state machine and the preview geometry are cheap (`GridEditorState` works on at most 64 zones and 32 tracks); the cost is building the SwiftUI sheet and the first preview panel, which needs a real display. A benchmark of the pure part has not been written, so nothing has been run. |
| Layouts window opens with 256 layouts | < 300 ms | not yet measured | Phase 4 (step 4.4). Library read (`layouts.json` at its 1 MB limit) plus the sidebar of thumbnails. Needs a real display; no benchmark exists yet. |

**Shift-drag overlay latency, where the time goes (QA pass 3, 2026-11-10, owner's machine, TextEdit; DEBUG stage trace plus a standalone `AXObserver` probe).** End to end the overlay appears a median 127 ms after the first drag event (p95 132). About 110 ms of that is before Lintel sees anything: the standalone probe, a bare `AXObserver` with no Lintel code, received its first `kAXMovedNotification` a median 110 ms after the first drag event, while `CGWindowListCopyWindowInfo` already showed the moved window about 8 ms after it. Inside Lintel the engine takes about 1.5 ms (p95 5 ms) and the overlay plus the compositor about 15 ms. So the delay is the delivery of the Accessibility notification by the app (TextEdit/AppKit) and the system, which the plugin cannot shorten. **The original 50 ms budget was not reachable for snapping that is driven by Accessibility move notifications, for apps that deliver them this late. Owner decision (2026-11-10): the budget for notification-driven overlay appearance is 150 ms**; the measurement above (median 127 ms, p95 132 ms) meets it, with about 20 ms of margin at p95. The 110 ms the app and the system take to deliver the notification is outside the plugin's control, so the budget is an end-to-end one for apps like TextEdit; an app that delivers the notification later will exceed it without a fault in the plugin. Every other budget in this section is unchanged. Evidence: `qa68c/trace.txt`, `n2-a.txt`, `axobs-a.txt` of the QA pass.

Documented option, **not implemented** (the owner chose to relax the budget instead; it is a change of the drag trigger, which the spec fixes, so it would need a decision): start the drag from the pointer, not from the notification. A global `NSEvent` monitor for `.leftMouseDragged` plus `NSEvent.modifierFlags` (Shift) and a `CGWindowListCopyWindowInfo` hit test of the window under the cursor at the first drag event would show the overlay about 10 ms after the drag begins; the Accessibility notification would then only confirm that the window moved. As far as the documentation says this needs no permission beyond Accessibility (mouse events of a global monitor are not gated by Input Monitoring, unlike key events; window bounds from `CGWindowList` need no Screen Recording permission), but that has **not been verified on a real Mac**, and a drag of something other than a window title bar (a text selection with Shift held) would have to be told apart by the hit test and the later notification. It would also add a second source of truth for "a window is being dragged", so it must stay behind the drag machine in `WindowsPlugin` and inside the plugin contract (no `LintelKit` change).

The zone benchmarks (`Tests/WindowsPluginTests/ZoneBenchmarks.swift`, off by default: `LINTEL_BENCHMARKS=1 swift test -c release --filter ZoneBenchmarks`) time the engine against the fake client and the pure drag and overlay data code; they print medians and need no display. They have **not been run**: on the agent's machine `swift test -c release` stops at a link error in `ClipboardPluginTests` (unrelated to this feature), so no figure is recorded here. Whatever they print still leaves out the Accessibility calls and the real panels, so the budget rows above stay "not yet measured" until someone measures them on a real Mac.
| Parking constants (sliver, echo tolerance 2 pt, watchdog rate, per-app timeout 0.25 s) | ADR 0009 rows 1 to 6, 10 | not yet measured | The spike on a real Mac. |

## Notes workspace (spec: Notes workspace, budgets of the spec; none measured yet)

None of these figures has been measured. The Notes workspace adds no search source, so the launcher panel keeps its < 50 ms show budget. The typing row is in the first table of this file and the revise rows are in the section below.

| What | Budget | Measured | How to measure |
|---|---|---|---|
| Open a note of 20 000 characters, to first paint | < 150 ms | not yet measured | Release build, `--qa-notes`, a 20 000 character note, stopwatch or Instruments signpost |
| Typing latency, notes up to 50 000 characters | < 16 ms per keystroke (the editor's own p99 row is < 8 ms) | not yet measured | `EditorBenchmarks` (off by default) and a real window |
| List of 1 000 summaries | < 200 ms | not yet measured | Scripted sources with 1 000 notes, time `NotesWorkspaceModel.refresh()` |
| Window search, fan-out | within the 150 ms per-source budget | not yet measured | Time a query against a scripted slow source; the budget cut is tested on a manual clock |
| `notes.sqlite` writes | off the main thread | not yet measured | Time Profiler on a typing session |
| Size of one document's history | per document below the pruning cap (200 revisions) | not yet measured | 200 revisions of 200 000 characters would be about 40 MB; compress only if a real document is above budget |

### Notes revise run (spec: Notes workspace, steps 6.2 and 6.4)

The agent rewrites only the commented blocks on the notes model (`ReviseService`, `ReviseNotesPrompt`, `ReviseGuard`). It
shares the 8192 context and the model file with the meeting notes, so the memory rows of the section above apply
unchanged. Nothing below is measured yet.

| Budget | Value | Measured | How |
|---|---|---|---|
| One run on one commented block (a few lines of context, a 4B model, warm file cache) | aim: under 10 s from the click to the new text on an M4 Max, model already resident | not yet measured | Release build. `LINTEL_REVISE_LLM_MODEL=<gguf> swift test -c release --filter RealReviseTests`; read `REVISE-BENCH … seconds=` (generation only, model resident after the first case). |
| First run after the model was unloaded | the load time of the model plus the row above | not yet measured | The first `REVISE-BENCH` line of a fresh process, or in the app after the 60 s keep-warm. |
| A run with six units (the `mixed-structure` case) | aim: under 30 s on an M4 Max | not yet measured | `REVISE-BENCH name=mixed-structure`. |
| Time from the click to the locked editor ("Agent is writing notes") | < 100 ms; flushing the typed text is one write | not yet measured | In the app with a stopwatch on a note with 50 000 characters; the lock strip must show before the model is asked. |
| Time the editor stays locked | only while generating, validating and applying; never more than the 10 minute limit | not yet measured | Same run; the strip must go when the answer is applied or refused. |
| Memory while the run holds the model | the notes model's residency (3.3 GB for the 4B) plus an 8192 context; not set separately | not yet measured | `footprintMB` of the `REVISE-BENCH` lines; `footprint <pid>` in the app. |
| Quality of the revisions | no figure promised: `ReviseGuard` keeps everything outside the commented blocks and refuses new links, images, HTML and a changed block structure; it does not check that the new text is right | not yet measured | `RealReviseTests` on the corpus (`Tests/NotesPluginTests/Fixtures/revise/`) and on three real Polish notes; record the `outcome` and the counts, read the revised blocks against the comments. |

### How the Notes editor row is measured (step 4.1)

The budget is the time from a key press to the updated line on screen at 50 000 characters. Two parts:

- **Text path, headless** (`Tests/NotesPluginTests/Editor/EditorBenchmarks.swift`, off by default): per keystroke the
  insert into the text storage, the scan for block boundaries, the restyle of the one edited block and the
  `onEdit` callback (the whole text as a `String`), 300 keystrokes each at the start, middle and end of a document
  of about 50 000 characters. `LINTEL_BENCHMARKS=1 swift test -c release -Xswiftc -enable-testing --filter EditorBenchmarks`.
  It has no layout, drawing or event path, so it is a lower bound.
- **Real window** (still to do): a release build with `--qa-notes --qa-setting plugins.notes.qaEditor=on` and a
  50 000 character note, typing through `NSEvent` key events (key repeat, the Polish dead keys and marked text
  included), measuring key-down to the next display with a signpost around `keyDown`. Only this number is entered
  in the table above. ADR 0008 addendum 0.1 measured the TextKit 2 layout and display side at p99 1.5 ms in a
  headless window; that run did not include the event path, the compositor or other hardware.
