# MEET-1.6 — Zgoda uczestników: zdanie do skopiowania

Source doc: .ai/specs/backlog/2026-11-13-epic-meeting-notes-beyond-claude.md (story MEET-1.6)

## Goal
Przycisk „Kopiuj komunikat” w przypomnieniu o zgodzie w HUD; zdanie en/pl trafia do schowka, czas kopiowania do `meeting.consent_text_copied_at`, okno spotkania pokazuje „Komunikat skopiowany o HH:MM”.

## Scope
`MeetingsPlugin` (HUD, kontroler, store, okno), jedna addytywna migracja `v2-consent`, `Localizable.xcstrings`, BC §2.

## Non-goals
`NotesPipeline`, `NotesGuard`, `NotesComposer`, `NotesPrompt`, `TranscriptChunker`, zapis segmentów. Żadnych logów treści.

## Risks
Migracja `meetings.sqlite` (risk-high): addytywna, nullable kolumna. Zrzuty QA HUD/okna wymagają nagrania w buildzie debug.

## Progress

### Phase 1: Implementacja

- [x] 1.1 Migracja `v2-consent`, store, `MeetingDocument`
- [x] 1.2 Akcja HUD „Kopiuj komunikat”, kontroler, zdanie en/pl
- [x] 1.3 Linia w oknie spotkania
- [x] 1.4 Testy (HUD, kontroler, migracja, skan języka) i bramka
- [ ] 1.5 Zrzuty QA jasny/ciemny
