# Dictation self-correction regression corpus (C1)

## Goal
Add a synthetic, test-only corpus of self-corrections for dictation formatting (owner decision 7, prep for CleanupPrompt v2).

## Scope
- `Tests/DictationPluginTests/Fixtures/autocorrect/cases.json` (>= 40 pl, >= 20 en, all invented)
- `Tests/DictationPluginTests/AutocorrectCorpusTests.swift`: fixture validity, expected vs must_keep/must_drop, coverage, FormatterGuard measurement (no blocking assertion), real-model test off by default.

Non-goals: CleanupPrompt, FormatterGuard, any production code.

## Risks
Low: test-only.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Corpus and tests

- [ ] 1.1 Fixture JSON
- [ ] 1.2 Swift Testing suite and real-model test
- [ ] 1.3 Full gate
