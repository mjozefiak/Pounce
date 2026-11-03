# ADR 0005: Built-in LLM for dictation formatting (llama.cpp)

- Status: proposed (step 4.0 measured on 2026-11-02; the engine choice is the product owner's)
- Date: 2026-11-02
- Spec: `.ai/specs/2026-11-01-voice-dictation.md`, Phase 4 (Q9)

## Context

Formatting calls the user's own OpenAI-compatible server on loopback (ADR 0004). That works, but the
speech model installs from Settings with a progress bar and the formatting model does not: the user
has to install Ollama, pull a model and pick it. A cold model also costs seconds on the first chunk
(observed: 13 s for `devstral-small-2` on the first request, longer than the 5 s + 0.2 s/word
timeout, so the first dictation after a pause fell back to raw text).

The speech engines need no inference runtime of their own because they are Core ML models, which
macOS runs itself. Language models are shipped as GGUF (llama.cpp) or as MLX weights, so a built-in
formatter needs an engine inside Pounce.

## Options

| | llama.cpp (GGUF) | MLX Swift (`mlx-swift-lm`) | Ollama `/api/pull` |
|---|---|---|---|
| Runs in the Pounce process | yes | yes | no, the user's Ollama downloads and runs it |
| Integration | official prebuilt `llama` XCFramework as a SwiftPM `binaryTarget` (pinned release and checksum); C API, Swift examples in the repo | SwiftPM package, native Swift; downloads through `swift-huggingface` and `swift-transformers` (two more dependencies) | none (loopback HTTP, streaming progress) |
| Model ecosystem | widest: Qwen3 Instruct, Bielik and most others as GGUF | smaller; fewer Polish models, conversion may be needed | whatever Ollama offers |
| Apple silicon | Metal backend | native, Apple-maintained | n/a |
| Fit with `ModelManager` | one `.gguf` file per model: fits the existing pinned-revision, SHA-256, resumable download | its own Hub downloader would bypass `ModelManager` unless the loader is fed local files | not our download |
| Cost | C++ binary in the app (size to be measured, step 4.0); untrusted-file parser in process | two extra Swift dependencies; Swift 6 strict-concurrency status to be verified | requires Ollama |

## Decision

1. **Engine: llama.cpp**, linked as the official XCFramework, wrapped by a narrow Swift actor
   (`LlamaRuntime`) behind a protocol so everything else is testable with a stub. Chosen for the
   breadth of GGUF models, Polish ones included. MLX Swift stays a candidate if step 4.0 shows a
   clear speed or memory win; the `LLMRuntime` protocol keeps that swap local.
2. **Models are downloaded by the existing `ModelManager`**: Hugging Face allow list, pinned
   revision, SHA-256 per file, resumable, atomic rename, into `Plugins/dictation/llm/`. The engine
   never touches the network.
3. **Catalog only.** GGUF parsing is untrusted-input parsing inside the process, so v1 loads only
   files from the catalog whose hash matches; a user-chosen GGUF file is out of scope.
4. **Non-thinking models** for the built-in path (Instruct-2507 variants, Bielik) with greedy
   sampling (`temperature` 0), so the chat template needs no `enable_thinking` switch. `<think>`
   stripping and `FormatterGuard` stay as the safety net.
5. **Lifecycle:** loaded in the background when recording starts (warm-up), released after
   `keepWarmMinutes`, decoding on its own thread with a cancellation flag checked every token.
   Disabled by default; the local server stays available and unchanged.
6. **Candidate models** (the ADR 0004 shortlist as GGUF): Qwen3-4B-Instruct-2507,
   Bielik-11B-v3.0-Instruct, Qwen3-30B-A3B-Instruct-2507. See the proposal after the measurements.

## Measurements (step 4.0, 2026-11-02)

Machine: Apple M4 Max, 128 GB. Engine: a local llama.cpp build (commit `77d6ae4ac`, 2026-02-19, Metal, tensor API off on this chip), all layers on the GPU. Models: Q4_K_M GGUF from Hugging Face. Speeds from `llama-bench` (200-token prefill, 160-token decode, 2 runs); end-to-end from `llama-server` with Pounce's real `CleanupPrompt` (system prompt, four few-shot pairs, one 60-word Polish transcript with a self-correction), `temperature` 0, non-thinking.

| Model (Q4_K_M) | File | Peak RSS | Prefill | Decode | Server ready | First request | Warm request | Words out / in |
|---|---|---|---|---|---|---|---|---|
| Qwen3-4B-Instruct-2507 | 2.33 GB | 3.3 GB | 1298 tok/s | 114.7 tok/s | 1.4 s | 1.33 s | 0.77 s | 50 / 60 |
| Bielik-11B-v3.0-Instruct | 6.26 GB | 7.0 GB | 475 tok/s | 53.8 tok/s | 2.9 s | 3.22 s | 1.85 s | 40 / 60 |
| Qwen3-30B-A3B-Instruct-2507 | 17.28 GB | 18.9 GB | 991 tok/s | 95.2 tok/s | 1.6 s | 1.32 s | 0.70 s | 42 / 60 |

Quality on this one sample (a single transcript, so an anecdote, not a benchmark; the real comparison is step 4.5):
- The speaker said "deployment on staging, actually on production, not on staging" and "at ten, no, at eleven".
- Qwen3-30B-A3B applied both corrections (11 o'clock, production). Qwen3-4B applied the production correction but kept "o dziesiątej, nie to znaczy o jedenastej". Bielik-11B applied the time correction but kept the wrong environment (staging).
- All three outputs pass `FormatterGuard` (ratio 0.67 to 0.83); Bielik and Qwen3-30B are close to the 0.6 lower bound on a text with many fillers.

Caveats:
- The model files were in the OS file cache, so the ready times exclude a cold read from disk.
- The numbers above are from `llama-server` over loopback; the in-process check is below.
- The tail budget of ADR 0004 (< 3 s for a 60-word tail) is met by all three models on this Mac; Bielik's first request (3.22 s) is on the edge.

In-process check (step 4.1, `LlamaRuntime` on the llama.cpp `b11600` XCFramework, a debug build of the tests, Qwen3-4B-Instruct-2507 Q4_K_M, the 13-word sentence "yyy no więc jutro mamy spotkanie…"): load 0.28 s, first request 0.77 s, second 0.55 s, so the in-process engine is in line with `llama-server`. The embedded `llama.framework` (arm64 slice only) is 12 MB and the whole app is 35 MB.

Proposal for the catalog, to confirm in step 4.5 on the regression set:
- **Default: Qwen3-4B-Instruct-2507 Q4_K_M** (2.3 GB file, about 3.3 GB resident, about 1 s per chunk).
- **Best quality for 32 GB Macs and up: Qwen3-30B-A3B-Instruct-2507 Q4_K_M** (17 GB file, about 19 GB resident). It was as fast as the 4B model on this machine because it is a mixture of experts with 3B active parameters.
- **Bielik-11B-v3.0-Instruct stays listed only if step 4.5 shows a Polish gain**: here it was the slowest and the least accurate on the corrections.

## Prompt regression on the built-in engine (step 4.5, 2026-11-03)

The nine cleanup fixtures of step 2.5 run through `BuiltInFormatter` and `LlamaRuntime` with Qwen3-4B-Instruct-2507
Q4_K_M (SHA-256 verified), model already loaded, M-series Mac:
`POUNCE_LLAMA_MODEL=<gguf> swift test --filter CleanupFixtureTests/builtInModel`.

| Fixture | Result | Time |
|---|---|---|
| pl-fillers | fillers gone, but the corrected-away "dziesiątej" stays: "…o dziesiątej, nie o jedenastej…" | 0.80 s |
| pl-question, pl-command | question and command only cleaned, not answered or run | 0.60 s |
| en-fillers, en-question, en-command | pass | 0.44–0.47 s |
| mixed-terms | pass (pull requesta, branch, code review kept) | 0.53 s |
| pl-enumeration | pass, but "po pierwsze/po drugie" words are dropped | 0.53 s |
| pl-self-correction | fail: "spotkajmy się we wtorek a nie czekaj w środę" came back as "Zajmijmy się we wtorek, a nie czekaj w środę" (wrong word, correction not applied) | 0.54 s |

7 of 9 pass, no fallbacks to raw, 0.4 to 0.8 s per chunk. Both failures are spoken self-corrections in Polish: the
4B model keeps both versions and once changed a word. Questions and commands are never answered, which was the
main risk. Not measured here: the 30B-A3B model and Bielik (large downloads); the catalog keeps Qwen3-4B as the
default and Bielik stays out until a run shows a Polish gain on these two cases.

## Consequences

- Formatting works without installing anything else; the first-dictation cold start is ours to
  fix with warm-up and `keepWarmMinutes`.
- New binary dependency (MIT) and a memory budget separate from the idle budget; both are
  recorded in `AGENTS.md`, `docs/perf.md` and `THIRD_PARTY_NOTICES.txt` in step 4.4.
- Model licences (Qwen3 and Bielik are Apache-2.0 per ADR 0004) are listed in the notices.
- The Ollama pull idea is dropped; the loopback server option is kept for people who already run one.

## Sources

- llama.cpp XCFramework and Swift example: https://github.com/ggml-org/llama.cpp/blob/master/docs/xcframework.md
- mlx-swift-lm: https://github.com/ml-explore/mlx-swift-lm
- ADR 0003 (speech engines on Core ML), ADR 0004 (formatting model and chunk size)
