# DICT-1.2: vocabulary panel in Settings → Dictation (part A of the mockup)

Source doc: .ai/specs/backlog/2026-11-13-epic-context-aware-dictation.md (story DICT-1.2)

## Goal
A "Vocabulary" section in the Dictation pane (add, edit, delete terms with variants), matching part A (A1–A10) of the owner-accepted mockup 1:1, decisions D1–D13.

## Scope
`DictationPlugin` (view, panel model, `VocabularyStore` state flags added additively), `Resources/Localizable.xcstrings` (en + pl), DEBUG QA flag, `docs/qa.md`, tests, SettingsKeyCoverageTests exempt entry for `plugins.dictation.vocabularyEnabled`.

## Non-goals
Parts B and C (Suggestions / auto-learning): no code, no dead UI. No new contracts; settings keys additive only.

## Risks
D6 (short-alias confirmation) vs D8 (short variant drawn literally) may conflict: follow the mockup, report the difference. Real dictation with a microphone cannot be checked in QA.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Model and store

- [x] 1.1 VocabularyStore state flags (set aside .corrupt, newer version read-only, write error) added additively — 99fac1a
- [x] 1.2 VocabularyPanelModel (add, edit, delete, conflicts, limits 8 words / 2000 entries, search, order) — cfe8372

### Phase 2: View

- [x] 2.1 Vocabulary section views per mockup A1–A10 (rows, tokens, form with live example, states, delete) — cfe8372
- [x] 2.2 en + pl strings, VoiceOver, keyboard, Reduce Motion, text sizes
- [x] 2.3 QA flag with invented vocabulary, docs/qa.md, SettingsKeyCoverageTests update

### Phase 3: Tests, gate, QA

- [x] 3.1 Panel model tests, full gate
- [ ] 3.2 Manual QA with screenshots vs mockup, PR comment

## Notes (implementation)

- D6 vs D8: both are drawn as in the mockup and do not exclude each other in code. Add is always active (errors appear after pressing it) except while a short single-word variant is not ticked "use anyway" (D8); Return in an empty variants field does nothing in that state.
- Short-variant warning text is the mockup's literal sentence ("also when you mean the letter"), also for variants that are not letters.
- A term equal to another entry's variant is rejected with its own message (not drawn in the mockup).
- Parts B and C: nothing implemented, no placeholder UI.
