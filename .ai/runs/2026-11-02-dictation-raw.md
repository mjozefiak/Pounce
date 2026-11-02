# Execution plan: Dictation, Phase 1 raw dictation (spec steps 1.2 to 1.10)

Source doc: .ai/specs/2026-11-01-voice-dictation.md
Branch: feat/dictation-raw (base: feat/dictation-contract, stacked on #15)

## Goal

Ship Phase 1 of the voice dictation spec: a `DictationPlugin` that records under a global shortcut,
transcribes with a local speech model (Parakeet Ultra through FluidAudio, Whisper large-v3-turbo through
WhisperKit as the second engine) and pastes the raw text into the app in front. No LLM cleanup (Phase 2) and
no history (Phase 3).

## Scope

Steps 1.2 to 1.10 of the spec, in order, one commit per step. Parts that cannot be automated stay manual and
are listed in the PR: the real model download (1.3), the real-model integration run (1.5, 1.10), the
measurements and the days of dogfooding (1.9), and the VoiceOver pass.

## Non-goals

- Anything from Phase 2 or Phase 3; step 1.1 (already in #15).

## Risks

- FluidAudio and WhisperKit are 0.x libraries; their API sits behind `SpeechEngine`.
- Neither library may download anything by itself: models load only from the `ModelManager` folder.
- The microphone grant is lost on every ad-hoc rebuild (docs/qa.md).

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Raw dictation

- [x] 1.2 Szkielet pluginu — aa14b7f
- [x] 1.3 ModelCatalog + ModelManager — dea0a45
- [x] 1.4 RecordingGesture
- [x] 1.5 AudioCapture + SpeechEngine/ParakeetEngine + DictationSession — 761b2b4
- [x] 1.6 TextPaster
- [x] 1.7 DictationHUD
- [x] 1.8 Ustawienia + onboarding + strona WWW
- [ ] 1.9 Pomiary
- [ ] 1.10 WhisperKitEngine
