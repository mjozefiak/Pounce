# Execution plan: Dictation, Phase 4 step 4.2 (catalog and download of GGUF models)

Source doc: .ai/specs/2026-11-01-voice-dictation.md
Branch: feat/dictation-llm-models (base: feat/dictation-llama-runtime, stacked on #22)

## Goal

Offer the built-in formatting models for download through the existing `ModelManager` (pinned revision,
SHA-256, resumable, atomic rename, allow-listed hosts), into `Plugins/dictation/llm/`.

## Non-goals

- Settings UI and progress bar (4.4), the formatter (4.3), user-chosen GGUF files (out of scope in v1).

## Risks

- A wrong pinned hash would make the download fail closed (nothing installed); a real download check
  (`RealLLMDownloadTests`) confirms size and SHA-256 against the real files.
- Rollback: revert this PR; nothing else uses the catalog yet.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 4: Built-in LLM

- [x] 4.2 LLMModelCatalog (Qwen3-4B default, Qwen3-30B-A3B), `llm/` manager, tests
