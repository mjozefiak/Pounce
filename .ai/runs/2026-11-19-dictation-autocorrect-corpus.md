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

- [x] 1.1 Fixture JSON — 9617832
- [x] 1.2 Swift Testing suite and real-model test — 9617832
- [x] 1.3 Full gate

### Phase 2: Review fixes

- [x] 2.1 Corpus corrections, ADR 0005 known-bad outputs, marker-only must_drop check
- [x] 2.2 Independent review fixes (reordering, ambiguous cases, digit forms, curly apostrophe, more negatives)
