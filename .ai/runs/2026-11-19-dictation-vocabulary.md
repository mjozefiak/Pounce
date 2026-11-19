# DICT-1.1 — user vocabulary and deterministic term replacement

Source doc: .ai/specs/backlog/2026-11-13-epic-context-aware-dictation.md (story DICT-1.1), ADR 0010.

Goal: the user's own terms (with spoken aliases) replace what the speech engine heard, without a model.
Scope: `TermReplacer` (pure, `LintelCore`), `VocabularyStore` (`vocabulary.json` via `AtomicFile`), the
`plugins.dictation.vocabularyEnabled` key, the hook after formatting, `eraseData`, BACKWARD_COMPATIBILITY §2/§3.
Non-goals: settings UI (DICT-1.2), app profiles (1.3), history migration (1.4), `CleanupPrompt`/`FormatterGuard` (PR #134).

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Core

- [ ] 1.1 TermReplacer with tests

### Phase 2: Plugin

- [ ] 2.1 VocabularyStore, setting, session hook, eraseData, tests
- [ ] 2.2 BACKWARD_COMPATIBILITY entries
