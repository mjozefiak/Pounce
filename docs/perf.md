# Performance measurements

Budgets from the MVP spec (`.ai/specs/2026-10-31-pounce-launcher-mvp.md`, Problem Statement and risk R6),
and what has been measured against them. Each row says where and how it was measured, so the next
measurement can be compared.

| Budget | Target | Measured | Status |
|---|---|---|---|
| File query, p95, 1 million entries (spec step 3.2) | < 30 ms on M1 | 6.6 ms (p50 3.8 ms, max 10.4 ms) on M4 Max, synthetic names | Met on M4 Max; an M1 run is still to do |
| Index memory per entry (R6) | about 100 B | 70 B (synthetic 1 M names), 83 B (fixture tree, 204 k entries) | Met |
| Memory at rest with an index of ~500 k files (spec step 3.6) | < 150 MB for the whole app | not measured on a real home folder yet | Manual item for the owner (see below) |

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

Machine: Apple M4 Max, 16 cores, macOS 27.0.1, release build, 2026-10-31.

### Results

| Measurement | 1 M synthetic names | 204 k fixture entries |
|---|---|---|
| Index size (`approximateBytes`) | 67.5 MB | 16.2 MB |
| Bytes per entry | 70 | 83 |
| Process footprint change | 93.9 MB | 21.9 MB |
| Query p50 / p95 / max | 3.8 / 6.6 / 10.4 ms | – |
| First full scan, including the first snapshot save | – | 294 ms |
| Snapshot on disk (LZFSE) | – | 0.7 MB |
| Snapshot load | – | 19 ms |

The fixture's names repeat a lot, so its snapshot compresses far better than a real one would.

### What this means for a real home folder

At 70–85 B per entry the index of a typical home folder (300–800 k entries after the default
exclusions, R6) takes 25–70 MB, and 1.5 M entries about 125 MB, against the spec's estimate of 100 B
per entry. The app's other memory (AppKit, SwiftUI, GRDB, icons) comes on top; the < 150 MB budget is
for the whole process at rest.

### Manual measurement on a real home folder

Agents never scan a real home folder (`docs/qa.md`). The owner measures it once on their Mac:

1. Build and run a release app (`scripts/make-app.sh`), allow Full Disk Access if wanted, finish the
   File Search step and wait until Settings → Files shows "N items indexed".
2. Wait a minute, then read Memory for Pounce in Activity Monitor (or
   `footprint -p $(pgrep -x Pounce)`).
3. Record here only the entry count, the memory and the machine. Never record paths or names.
