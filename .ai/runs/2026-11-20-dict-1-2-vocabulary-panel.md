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

- [ ] 1.1 VocabularyStore state flags (set aside .corrupt, newer version read-only, write error) added additively
- [ ] 1.2 VocabularyPanelModel (add, edit, delete, conflicts, limits 8 words / 2000 entries, search, order)

### Phase 2: View

- [ ] 2.1 Vocabulary section views per mockup A1–A10 (rows, tokens, form with live example, states, delete)
- [ ] 2.2 en + pl strings, VoiceOver, keyboard, Reduce Motion, text sizes
- [ ] 2.3 QA flag with invented vocabulary, docs/qa.md, SettingsKeyCoverageTests update

### Phase 3: Tests, gate, QA

- [ ] 3.1 Panel model tests, full gate
- [ ] 3.2 Manual QA with screenshots vs mockup, PR comment
