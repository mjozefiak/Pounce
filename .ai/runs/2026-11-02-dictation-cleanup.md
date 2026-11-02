# Execution plan: Dictation, Phase 2 formatting with a local LLM (spec steps 2.1 to 2.5)

Source doc: .ai/specs/2026-11-01-voice-dictation.md
Branch: feat/dictation-cleanup (base: feat/dictation-raw, stacked on #16)

## Goal

Add the optional "Porządkuj" mode: while recording, the transcript is cut into chunks of at most 60 words
and each chunk is cleaned by the user's own OpenAI-compatible server on this Mac (Ollama, LM Studio,
llama-server). A chunk the model cannot clean comes back raw. Add "Paste raw version of the last dictation".

## Scope

Steps 2.1 to 2.5 of the spec. Whatever needs a real server stays manual and is listed in the PR.

## Non-goals

- History and Erase Data (Phase 3), an embedded LLM, custom prompts or modes, per-app rules.

## Risks

- A new network client: loopback only, enforced by `LoopbackPolicy` and checked again by the transport.
- The model may answer a dictated question: the prompt, the examples and `FormatterGuard` limit it, and the
  raw version is always one command away.
- No `PounceKit` change in this phase.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 2: Formatting with a local LLM

- [x] 2.1 EndpointProbe + LoopbackPolicy
- [x] 2.2 LocalLLMFormatter + CleanupPrompt + FormatterGuard
- [x] 2.3 Segmenter and formatting while recording
- [x] 2.4 Settings and HUD for formatting, dictation.pasteLastRaw
- [x] 2.5 Prompt regression fixtures (the run against a real server is manual)
