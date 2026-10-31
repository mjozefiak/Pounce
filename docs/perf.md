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
| Memory at rest with an index of ~500 k files | < 150 MB for the whole app | 85 MB after launching from the saved index (510 k entries); 199–222 MB for the rest of the session in which the first scan ran | Met at rest after a restart; **not met right after the first scan** (see below) |
| First scan of `~` | < 30 s | 1.6–1.9 s for 510 k entries of a synthetic tree on the SSD | Met on the synthetic tree; a real home folder is a manual item |
| Start from the saved index until ready | < 2 s | 0.19 s from process start to "Loaded 510020 index entries" | Met |
| Index memory per entry (R6) | about 100 B | 67–70 B (synthetic), 83 B (fixture tree, 204 k entries) | Met |

### How the app-level rows were measured

The panel, memory and start-up rows come from the running app. QA mode keeps the run away from the
tester's data (`docs/qa.md`), and its launch arguments exist only in DEBUG builds, so the measurement
build is a release build with QA compiled in. It is never shipped:

```bash
swift build -c release -Xswiftc -DDEBUG --scratch-path /tmp/pounce-perf-build
BIN=/tmp/pounce-perf-build/out/Products/Release/Pounce
FIX=/tmp/pounce-p4-bench/tree   # the benchmark tree below, POUNCE_BENCH_FOLDERS=5000 (510 020 entries)
COMMON=(--qa --qa-data-root /tmp/pounce-perf/data --qa-setting "plugins.files.qaHome=$FIX"
  --qa-setting "plugins.files.roots=$FIX" --qa-setting plugins.files.setupCompleted=true
  --qa-full-disk-access granted --qa-setting "plugins.apps.roots=$APP_FIXTURES"
  --qa-setting plugins.apps.spotlight=false --qa-spotlight off --qa-accessibility denied
  --qa-setting app.onboarding.shortcutCompleted=true)
/usr/bin/log stream --predicate 'subsystem == "app.pounce"' --info --style compact &
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
  POUNCE_BENCHMARKS=1 swift test -c release -Xswiftc -enable-testing --filter AppBenchmarks
  ```

### Memory right after the first scan

In the session that runs the first scan of 510 k entries, the footprint stays at 199–222 MB, above the
budget, until Pounce is restarted; launched from the saved snapshot, the same index takes 85 MB. `heap`
on the process shows only 54 MB of live allocations (48 MB of them the index arrays); `vmmap -summary`
shows the rest as freed memory the allocator keeps: "Malloc Large (empty)" 104 MB and "Malloc Small
(empty)" 41 MB dirty. They come from the scan's folder listings, the copy made while a batch is applied
and the snapshot encoder's buffers. `malloc_zone_pressure_relief` was tried and released nothing on
macOS 27, so this release ships no change for it. It affects only the first scan (and a full rescan);
every later launch is at rest at 85 MB. A follow-up could reuse the scan buffers instead of reallocating
them, or scan in a helper process.

## File index (Phase 3)

### How it was measured

`Tests/FilesPluginTests/Benchmarks.swift`, off by default:

```bash
POUNCE_BENCHMARKS=1 swift test -c release -Xswiftc -enable-testing --filter FileBenchmarks
```

- **Search:** `syntheticStore(count: 1_000_000)` (the generator from the tests: ten words, six
  extensions, nested folders, one folder per 20 entries), then 20 queries × 5 rounds through
  `FileSearch.search` with `limit: 50`, the same call the search source makes. Queries cover exact
  words, acronyms (`pln`, `bgt`), multi-word queries, a single letter and a query with no match.
- **Scan:** a fixture tree of fake names generated under `/tmp/pounce-p3-bench/tree` (2,000 folders ×
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
2. Wait a minute, then read Memory for Pounce in Activity Monitor (or
   `footprint -p $(pgrep -x Pounce)`).
3. Record here only the entry count, the memory and the machine. Never record paths or names.

Also still to do by the owner for v1.0, because an agent cannot do them:

- The time of the first scan of the real home folder (Settings → Files shows "Indexing…" until it
  ends; < 30 s).
- The whole budget table on an M1 Mac, the slowest supported machine.
- Opening the panel with the real global shortcut while another app is active (the QA run above opens
  it at launch and never registers a hotkey). Run
  `/usr/bin/log stream --predicate 'subsystem == "app.pounce"' --info` and press the shortcut ten
  times; read "Panel ordered front in … ms".
