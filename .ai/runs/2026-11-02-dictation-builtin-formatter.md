# Execution plan: Dictation, Phase 4 step 4.3 (BuiltInFormatter)

Source doc: .ai/specs/2026-11-01-voice-dictation.md
Branch: feat/dictation-builtin-formatter (base: feat/dictation-llm-models, stacked on #23)

## Goal

Format a dictation with the model that runs inside Pounce: the same prompt, segmenter and guard as the
server formatter, a warm-up while the user speaks, and a raw fallback when the model is missing, fails or is
too slow. Selected by two new settings keys; the Settings UI is step 4.4.

## Non-goals

- Settings UI and model download buttons (4.4), the fixture regression run on the built-in model (4.5).

## Risks

- Settings keys `plugins.dictation.llmSource` and `plugins.dictation.builtInLLMModel` become a protected
  contract once released (`BACKWARD_COMPATIBILITY.md` §3).
- A model load cannot be interrupted: the formatter gives up at its time limit without waiting for it.
- Rollback: revert this PR; the default source stays the user's server.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 4: Built-in LLM

- [x] 4.3 BuiltInFormatter, warm-up on record, settings keys, tests
