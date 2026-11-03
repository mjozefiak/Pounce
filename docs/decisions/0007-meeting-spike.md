# ADR 0007: Meeting notes spike (step 0.0)

- Status: partial. Items marked ⚠ could not be verified by an agent and are in the owner's manual test plan (`docs/qa.md`).
- Date: 2026-11-03
- Spec: `.ai/specs/2026-11-03-meeting-notes.md`, step 0.0 (Q13)

## Results

| # | Question | Result | Decision |
|---|---|---|---|
| 1 | License and attribution of the diarization weights | Verified from the Hugging Face card of `FluidInference/speaker-diarization-coreml`: the Community-1 Core ML artifacts (`Segmentation`, `FBank`, `Embedding`, `PLDA`, `PldaRho`) are converted from `pyannote/speaker-diarization-community-1` and distributed under **CC-BY-4.0** (card says `scoped-cc-by-4.0`, see its `NOTICE.md`). The legacy files (`pyannote_segmentation`, `wespeaker*`) are MIT and CC-BY-4.0. FluidAudio itself is Apache-2.0. | **Compatible** with the project's MIT license when attribution is shown. Diarization stays on. Step 1.6 adds the attribution to `THIRD_PARTY_NOTICES.txt` and the About window, and pins the files by SHA-256 (the card carries `provenance.json`). |
| 2 | Quality on Polish meetings | ⚠ Not measured: needs two recordings of real meetings and the owner's judgement. | Fallback "Ja / Inni" by channel exists, so this does not block. Manual test plan item. |
| 3 | Memory and time of offline diarization for 3 h; effect of the trait on binary size | API read: `OfflineDiarizerManager.process(audioSource: AudioSampleSource, …)` and `prepare(audioSource:)` take a **streaming** sample source (the array form just wraps `ArrayAudioSampleSource`), so the diarizer can read from a decrypting `SpoolReader` without a plaintext WAV (Q15). ⚠ Peak memory for 3 h and the binary size delta are **not measured**. | Implement the streaming path first; step 1.6 keeps the memory guard and the "Ja / Inni" fallback, and measures with a disabled-by-default benchmark. |
| 4 | System audio tap under hardened runtime and ad-hoc signing | ⚠ Not verifiable by an agent: it needs the "System Audio Recording" consent prompt and real audio. Findings so far: `Resources/Pounce.entitlements` already holds `audio-input` and `disable-library-validation`; Apple documents no extra entitlement for a Core Audio process tap, only `NSAudioCaptureUsageDescription`. | Per the decision rule, step 1.4 builds `SystemAudioSource` behind the `plugins.meetings.systemAudio` flag, and the record command falls back to the microphone track alone if the tap cannot start. The privacy pane id `Privacy_AudioCapture` is unconfirmed (manual item). No entitlement is added until a manual test shows one is needed. |
| 5 | `kAudioProcessPropertyIsRunningInput` | ⚠ Not verified (needs a running Zoom/Meet and a Bluetooth headset). | Phase 3 starts with this check (step 3.1), as the spec says; a negative result ends Phase 3 only. |
| 6 | Loading diarization models without the network | API read: `OfflineDiarizerModels.load(from:)` takes a local folder; `prepareModels(…)` is the downloading path and must not be used. | `FluidDiarizer` uses only the folder path owned by `ModelManager`. Step 1.6 adds a test that fails on any network access. |

## Correction to the spec

FluidAudio 0.18.2 defines `Diarizer` as an **opt-out** trait (`.default(enabledTraits: ["NemoTextProcessing", "TTS", "Diarizer"])`). Pounce passes `traits: []`, so diarization is off today and `traits: ["Diarizer"]` is the right change; the spec's wording "opt-in" is only a difference in how the trait is described.

## Go / no-go

**Go.** No rule from "Tryb realizacji" fires on verified facts: the license is compatible. The unverified items (2, 3-memory, 4, 5) each have a prepared fallback and are handed to the owner.
