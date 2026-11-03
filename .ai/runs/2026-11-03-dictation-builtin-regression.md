# Execution plan: Dictation, Phase 4 step 4.5 (prompt regression on the built-in engine)

Source doc: .ai/specs/2026-11-01-voice-dictation.md
Branch: feat/dictation-builtin-regression (base: feat/dictation-builtin-settings, stacked on #25)

## Goal

Run the step 2.5 cleanup fixtures against `BuiltInFormatter` with the real Qwen3-4B model, record the result and
the catalog decision. Opt-in test only; no production code changes.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 4: Built-in LLM

- [x] 4.5 Opt-in fixture test on the built-in engine, results in ADR 0005
