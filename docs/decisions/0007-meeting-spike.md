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
| 4 | System audio tap under hardened runtime and ad-hoc signing | ⚠ Not verifiable by an agent: it needs the "System Audio Recording" consent prompt and real audio. Findings so far: `Resources/Lintel.entitlements` already holds `audio-input` and `disable-library-validation`; Apple documents no extra entitlement for a Core Audio process tap, only `NSAudioCaptureUsageDescription`. | Per the decision rule, step 1.4 builds `SystemAudioSource` behind the `plugins.meetings.systemAudio` flag, and the record command falls back to the microphone track alone if the tap cannot start. The privacy pane id `Privacy_AudioCapture` is unconfirmed (manual item). No entitlement is added until a manual test shows one is needed. |
| 5 | `kAudioProcessPropertyIsRunningInput` | ⚠ Not verified by an agent (needs a running Zoom/Meet and a Bluetooth headset). Step 3.1 built `CoreAudioProcessObserver` against these properties (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`, `…BundleID`, `…PID`; macOS 14.2+, listeners, no polling) and it compiles; no test runs it. | The observer reports `.unavailable` when the process list cannot be read or no process answers the input property, and suggestions then switch themselves off. The owner verifies with `docs/qa.md`, "Meetings detection"; a negative result ends Phase 3 only. |
| 6 | Loading diarization models without the network | API read: `OfflineDiarizerModels.load(from:)` takes a local folder; `prepareModels(…)` is the downloading path and must not be used. | `FluidDiarizer` uses only the folder path owned by `ModelManager`. Step 1.6 adds a test that fails on any network access. |

## Correction to the spec

FluidAudio 0.18.2 defines `Diarizer` as an **opt-out** trait (`.default(enabledTraits: ["NemoTextProcessing", "TTS", "Diarizer"])`). Lintel passes `traits: []`, so diarization is off today and `traits: ["Diarizer"]` is the right change; the spec's wording "opt-in" is only a difference in how the trait is described.

## Go / no-go

**Go.** No rule from "Tryb realizacji" fires on verified facts: the license is compatible. The unverified items (2, 3-memory, 4, 5) each have a prepared fallback and are handed to the owner.

## Step 1.6 (diarization): decisions and open items

### Spool format (chosen in step 1.3)

One file per track, `Plugins/meetings/Spool/<uuid>/{mic,system}.spool`: a 44-byte header (magic `PNCSPOOL`, version 1, track byte, meeting UUID, 16-byte random salt), then frames of at most 2 s of 16 kHz mono signed 16-bit little-endian samples. Each frame is `length (4 B BE) | flags (1 B) | AES-256-GCM ciphertext | 16 B tag`, nonce from the frame counter, a per-file sub-key (HKDF over the master key and the salt), the header, frame index, length and flags as authenticated data. The last frame carries the final flag, so a truncated file is distinguishable from a finished one. The reader decrypts sequentially; it cannot seek.

### Why the diarizer holds a track in memory

`OfflineDiarizerManager.process(audioSource:)` takes FluidAudio's `AudioSampleSource`, which is **random access** (`sampleCount`, `copySamples(offset:count:)`): segmentation windows overlap and embeddings are taken from spans, so the pipeline reads the same region more than once. A sequential decrypting reader cannot serve that, and a plaintext temporary WAV is forbidden (Q15). `FluidDiarizer` therefore reads **one track at a time** from `SpoolReader` into an `[Int16]` (2 bytes a sample, half of an array of `Float`) and serves FluidAudio through `PCM16SampleSource` (in `LintelSpeech`; MeetingsPlugin's own `AudioSampleSource` hides FluidAudio's of the same name). The tracks are diarized one after the other and the models are released right after the last one.

### Memory budget (UNMEASURED)

`DiarizationBudget` is a **duration** cap per track, **90 minutes** (`unmeasuredMaximumDuration`, 86.4 M samples, about 173 MB of `Int16`). It was first a sample count for 3 h 10 min; the review found that this bounds only the sample buffer. FluidAudio's clustering (AHC and VBx) works on the embeddings of the whole track (about one per two seconds per slot) and its distance matrices grow roughly with the square of that number, so the total memory is not linear in the duration and is **unknown for 3 h**. The 90 minute value is a conservative guess, **not a measurement**; it is marked "unmeasured, tighten after benchmark" in the code. **3 h diarization is NOT yet measured**: a track longer than 90 minutes is refused while it is read (`overBudget`, never more than the cap in memory), diarization is skipped, and the meeting falls back to channel labels (below). So a 3 h meeting currently has no speaker recognition. Measuring the real peak for 1 h, 90 min and 3 h is the disabled-by-default `DiarizationBenchmarks` test (`LINTEL_DIARIZATION_MODEL_FOLDER`, `LINTEL_DIARIZATION_BENCH_AUDIO`); it has **not** been run (no model and no real recording in the agent environment). Open item for the owner: run it, then raise or lower the cap. The buffer is appended chunk by chunk (no per-chunk `reserveCapacity`, which copied the array each time), the blocking read and decryption run off the finalizer's actor, and cancellation stops the read between chunks. A `failed` run of a track is retried once before the fallback.

**Fallback modes (resolved spec discrepancy).** The spec says that a failed, skipped or over-budget diarization sets `speaker_mode = channels` and shows the banner. The first implementation used `none` when only the microphone had speech. Decision (owner's delegate): the fallback is always `channels`. When both tracks have speech the microphone is "Ja" and the system track "Inni"; when only the microphone has speech (it may be a whole room) there is one neutral label "Mówca 1" without a claim of self, still in `channels` mode so the banner shows; when only the system track has speech it is "Inni". `none` is used only when the setting `plugins.meetings.diarization` is off. In `channels` mode "To ja" is refused (the speakers are tracks, not people); renaming works. A cancelled finalization (app quitting) is not a fallback: nothing is written, the meeting stays out of `ready` (`incomplete`) and its spool is kept.

### Models load from the folder only

The spec suggested `OfflineDiarizerModels.load(from:)`. Reading FluidAudio 0.18.2 shows that it (and `prepareModels()`) go through `ModelHub.loadModels`, which downloads whatever it finds missing or whose revision marker does not match FluidAudio's own, and after a failed load deletes the cache and downloads again. Lintel's `ModelManager` folder has no such marker, so those calls are never made. `FluidDiarizer.loadModels(from:)` opens `Segmentation`, `FBank` (CPU only, as FluidAudio does), `Embedding` and `PldaRho` with `MLModel(contentsOf:)`, decodes `plda-parameters.json` (`tensors.psi`) and uses the public `OfflineDiarizerModels` initializer. A missing or unreadable file is `modelsUnavailable` and a fallback; nothing is fetched or deleted. Tests: an empty folder and a folder of invalid models fail with a `URLProtocol` tripwire registered (zero requests), and a source scan fails on any forbidden call (`prepareModels`, `OfflineDiarizerModels.load`, `ModelHub`, `DownloadUtils`, `URLSession`).

### Catalog entry and license evidence

`ModelCatalog.diarizationCommunity1` (id `diarization-community-1`) pins `FluidInference/speaker-diarization-coreml` at commit `7eab74f3463c736418d0eb10296261ae581146c9` (the `main` head on 2026-11-03) and lists the 21 files FluidAudio loads (`Segmentation`, `FBank`, `Embedding`, `PldaRho` `.mlmodelc` and `plda-parameters.json`), 21.6 MB in total, from `huggingface.co` only (the allow list is unchanged). The repository's `PLDA.mlmodelc`, the legacy models and the `.mlpackage` sources are not used by FluidAudio 0.18.2 and are not in the entry. SHA-256 of every file was computed from the downloaded file at that revision; for the git-LFS files it equals the `lfs.oid` of the tree API, and every hash equals the one in the repository's `provenance.json`. The package is in `ModelCatalog.diarization`, not in `ModelCatalog.all` (the speech model list).

License evidence, read from the repository at that revision: `NOTICE.md` states that the CC-BY-4.0 `LICENSE` covers exactly `Segmentation`, `FBank`, `Embedding`, `PLDA`, `PldaRho`, `plda-parameters.json` and `xvector-transform.json` (the Community-1 derived artifacts); the underlying pipeline is pyannote's under CC-BY-4.0; the PLDA parameters are from BUT Speech@FIT, which licenses them under CC-BY-4.0 including commercial use. The attribution it asks for (pyannote, WeSpeaker, BUT Speech@FIT and Fluid Inference named, CC-BY-4.0 linked, files marked as modified Core ML conversions) is in `Resources/THIRD_PARTY_NOTICES.txt`, which the About window shows in full (there is no separate list in the window). FluidAudio itself (Apache-2.0) was already listed and now also names diarization.

### Package change and binary size

`Package.swift`: FluidAudio `traits: ["Diarizer"]` (it was `[]`; the trait is opt-out upstream, see the correction above) and the FluidAudio product added to `MeetingsPlugin`. The release binary size effect was **not measured** (no release build in this step). The debug build was checked to compile and link with the trait.

### Not verified in this step

- Diarization quality for Polish meetings (needs the owner's recordings).
- Peak memory and time for 1 h and 3 h (the benchmark is written, not run).
- A real model run end to end (no model files here); the diarizer, the clustering and the Core ML models were exercised only through fakes and through the failure paths.
