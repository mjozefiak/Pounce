# Execution plan: Dictation, Phase 4 step 4.4 (Settings for the built-in model)

Source doc: .ai/specs/2026-11-01-voice-dictation.md
Branch: feat/dictation-builtin-settings (base: feat/dictation-builtin-formatter, stacked on #24)

## Goal

Let the user choose "Built-in (Pounce)" next to "My server" in Settings → Dictation → Formatting, pick a
catalog model that fits the Mac's memory, download it with progress (same `ModelManager` path as the speech
model), cancel, remove it, and try it on the sample text.

## Non-goals

- The fixture regression run on the built-in model and the catalog decision about Bielik (4.5).

## Risks

- No new settings keys (the two keys from 4.3 are used); the default source stays the user's server.
- Removing the model unloads the runtime first so the file is not held open.
- Rollback: revert this PR; the source setting is then ignored by the UI but still honoured by the formatter.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 4: Built-in LLM

- [x] 4.4 Settings: source picker, model list, download/cancel/remove, Try it, strings, tests, docs
