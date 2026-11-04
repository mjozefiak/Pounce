# Run: meeting transcription and notes (spec 2026-11-03-meeting-notes)

Local stacked branches, never pushed: the active `gh` account (mjozefiak-vufinder) has no write access to
mjozefiak/Pounce (`push: false`), so no PR could be opened. Merge order = order below; each branch is based on
the previous one. Every unit had an independent review by a fresh agent; High and Medium findings were fixed in
follow-up commits before the next unit was stacked.

| # | Branch | Unit | Risk |
|---|---|---|---|
| 1 | feat/meeting-spike | 0.0 ADR 0007 | docs |
| 2 | feat/meeting-docs | 0.1 ADR 0006, AGENTS/BC/CODE_REVIEW | docs |
| 3 | feat/meeting-models-contract | 0.2 `modelsDirectory`, `ModelsMigration` | high |
| 4 | feat/meeting-speech-extract | 0.3 `PounceSpeech` | high |
| 5 | feat/meeting-model-leases | 0.4 leases, registry | high |
| 6 | feat/meeting-permission-contract | 1.1 `Permission.systemAudioRecording` | high |
| 7 | feat/meeting-store | 1.2 `MeetingsPlugin` skeleton, store | medium |
| 8 | feat/meeting-spool | 1.3 encrypted spool | high (crypto) |
| 9 | feat/meeting-audio-sources | 1.4 tap, self-test, echo | medium |
| 10 | feat/meeting-session | 1.5 `MeetingSession` | medium |
| 11 | feat/meeting-diarization | 1.6 diarization | medium |
| 12 | feat/meeting-recovery | 1.7 recovery, "Dokończ" | medium |
| 13 | feat/meeting-window | 1.8 exporter, window | medium |
| 14 | feat/meeting-settings | 1.9 settings, onboarding | medium |
| 15 | feat/meeting-record | 1.10 HUD, command, registration | high (user-visible) |
| 16 | feat/meeting-library | 1.11 library, landing page | medium |
| 17 | feat/meeting-notes | Phase 2 notes | medium |
| 18 | feat/meeting-suggest | Phase 3 suggestions | medium |

Step 1.12 (dogfooding) and every real-hardware check are the owner's: see "Meetings: owner manual test plan" in
`docs/qa.md`. Decisions and spec discrepancies are listed in ADR 0007 and in the final report of the run.
