# Execution plan: Dictation, Phase 4 step 4.1 (LlamaRuntime)

Source doc: .ai/specs/2026-11-01-voice-dictation.md
Branch: feat/dictation-llama-runtime (base: feat/dictation-builtin-llm-spec, stacked on #21)

## Goal

Put llama.cpp inside the Pounce process behind a narrow `LLMRuntime` port: load a GGUF file, generate a
chat completion with greedy sampling, cancel between tokens, free the model after a keep-warm interval.
Nothing uses it yet: `BuiltInFormatter` (4.3) and the model download (4.2) come next.

## Non-goals

- Downloading models (4.2), the formatter and Settings (4.3, 4.4), any `PounceKit` change.

## Risks

- New binary dependency (MIT): the official XCFramework `b11600`, pinned by URL and SHA-256 in `Package.swift`.
  It is a dynamic framework embedded by `scripts/make-app.sh` (arm64 slice only).
- It parses untrusted files (GGUF): v1 loads only catalog files with a verified hash (ADR 0005, step 4.2).
- Rollback: revert this PR; nothing else calls the runtime.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 4: Built-in LLM

- [x] 4.1 LlamaRuntime: XCFramework, `LLMRuntime` port, `LlamaRuntime` actor, `KeepWarmRuntime`, packaging, tests
