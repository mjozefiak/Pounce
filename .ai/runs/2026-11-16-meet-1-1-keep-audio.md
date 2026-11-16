# MEET-1.1 — `keepAudio`: opcjonalne zachowanie zaszyfrowanego audio

Source doc: .ai/specs/backlog/2026-11-13-epic-meeting-notes-beyond-claude.md (story MEET-1.1)

## Goal
Opt-in (`plugins.meetings.keepAudio`, domyślnie `false`) zachowanie zaszyfrowanego spoolu po `ready` na `keptAudioDays` (30) dni; nowy `AudioState.kept` bez zmiany schematu.

## Scope
- `MeetingsSettings`: `keepAudio`, `keptAudioDays`.
- `MeetingSession.markReady`, `MeetingResumer.markReady`/`closeWithoutAudio`, `RecoveryJob.removeLeftovers`: przy `keepAudio` spool zostaje, `audio_state = kept`.
- `RetentionJob`: wygasanie `kept` po `keptAudioDays` (od `ended_at`); usunięcie spotkania i `eraseData()` kasują spool jak dziś.
- `MeetingsPrivacy` + panel Prywatność: przełącznik, licznik, "Usuń zachowane nagrania" (arkusz potwierdzenia); wyłączenie przełącznika zostawia `kept` (panel mówi).
- Teksty `en`/`pl` (InfoPlist, Localizable), `BACKWARD_COMPATIBILITY.md` §2/§3/§5, `AGENTS.md`, poprawka Q7 w specu spotkań.

## Non-goals
Zbiór wzorcowy, odsłuch cytatu, pytanie przy pierwszym nagraniu (M-Q3: bez pytania), zmiana schematu SQLite.

## Risks
risk-high: retencja, format na dysku, nowy klucz ustawień. Nowy wiersz ustawień wymaga akceptacji właściciela (prototyp `set-meetings`). Audio nigdy jawne.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Rdzeń
- [ ] 1.1 Ustawienia keepAudio/keptAudioDays i AudioState.kept
- [ ] 1.2 Trzy ścieżki ready (sesja, resumer, RecoveryJob) i wygasanie w RetentionJob
- [ ] 1.3 Prywatność: liczenie i usuwanie zachowanych nagrań

### Phase 2: UI, teksty, dokumenty
- [ ] 2.1 Panel Prywatność (przełącznik, licznik, przycisk, arkusz)
- [ ] 2.2 Teksty en/pl i InfoPlist
- [ ] 2.3 BACKWARD_COMPATIBILITY, AGENTS.md, spec Q7
- [ ] 2.4 Pełna bramka i zrzuty QA
