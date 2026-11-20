# Parakeet language hint for meetings (issue #132)

Goal: step 1 of the fix plan in issue #132: pass the Settings language (`plugins.meetings.speechLanguage`) to Parakeet as FluidAudio's script hint.
Scope: `ParakeetEngine` (optional language closure, default none, so dictation is unchanged), `ParakeetLanguage.hint(for:)`, Meetings wiring. Non-goals: merging short segments / pre-roll (step 2), Whisper second pass (step 3), any new setting, any migration, PR #195 files.
Risks: the hint limits script, not language (about 19% of the wrong segments per the issue); not measured on audio here.

## Progress

> Convention: `- [ ]` pending, `- [x]` done.

### Phase 1: Hint

- [x] 1.1 ParakeetEngine language closure and mapping, Meetings wiring, offline tests
