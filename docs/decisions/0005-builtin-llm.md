# ADR 0005: Built-in LLM for dictation formatting (llama.cpp)

- Status: proposed (measurements of step 4.0 pending; the engine choice is the product owner's, 2026-11-02)
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
6. **Candidate models for step 4.0** (the ADR 0004 shortlist as GGUF): Qwen3-4B-Instruct-2507,
   Bielik-11B-v3.0-Instruct, Qwen3-30B-A3B-Instruct-2507. The default and the recommended list are
   fixed after the measurements below.

## Measurements still to take (step 4.0)

On the user's Mac, same cleanup request as step 2.5 (Polish, about 60 words), each model at Q4_K_M
(Bielik also Q6_K): load time, prefill and decode tokens/s, peak memory while loaded, XCFramework
size in the app, tail latency against the < 3 s budget of ADR 0004. Ollama on the same model is the
reference. No numbers are recorded here until they are measured.

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
