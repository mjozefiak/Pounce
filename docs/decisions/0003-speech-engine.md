# ADR 0003: Speech engine for dictation

- Status: accepted (replaces spike 0.1 of the dictation spec)
- Date: 2026-11-02
- Spec: `.ai/specs/2026-11-01-voice-dictation.md`, Phase 0

## Context

Spike 0.1 was going to compare FluidAudio/Parakeet with WhisperKit on 10–20 of the user's own
recordings (Polish, English, mixed). The user chose to decide from public benchmarks instead. The
target machine is a Mac Studio with 128 GB of unified memory, so model size is not the limit;
latency and Polish accuracy are. Dictation is mostly spontaneous Polish with English technical terms,
often 1–5 minutes long.

## Evidence (public benchmarks, collected 2026-11-02)

| Model | Polish WER | English WER | Speed on Apple silicon | Swift path | License | Size |
|---|---|---|---|---|---|---|
| **Parakeet Ultra** (post-trained Parakeet TDT v3, Sep 2026) | FLEURS 5.54 (v3: 6.70) per model card [C]; 6.16 (v3: 7.37) on Handy, Q8 [B] | FLEURS-en 3.55 (v3: 4.25) [C] | same architecture as v3: ~110× real time on M4 Pro [D], 190–210× per FluidAudio [E] | FluidAudio, CoreML/ANE; FluidAudio's recommended model [E] | weights CC-BY-4.0, SDK Apache-2.0 | ~0.7 GB [B] |
| Parakeet TDT 0.6B v3 | FLEURS 7.31, MLS 7.28 [A]; 7.37 (Q8) [B] | Open ASR avg 6.32 [A] | as above | FluidAudio | CC-BY-4.0 | ~0.7 GB |
| **Whisper large-v3-turbo** | FLEURS 5.81 (Q8) [B] — ahead of Parakeet Ultra on the same benchmark | LibriSpeech 2.03 [G] | slower than Parakeet; no verified M-series RTF | WhisperKit (MIT) | MIT | ~0.6–1 GB CoreML [G] |
| Whisper large-v3 | FLEURS 4.74, MLS 8.88 [A]; 4.69 (Q8) [B] | Open ASR avg 7.44 [A] | ~13× slower than Parakeet on GPU [A] | WhisperKit | MIT | 1.55 GB |
| Canary-1B-v2 | FLEURS 6.64 [A] | Open ASR avg 7.15 [A] | no CoreML/MLX port | none | CC-BY-4.0 | 1.07 GB |
| Cohere Transcribe 2B | FLEURS 6.15 (Q8) [B] | Open ASR avg 5.42 (vendor) [I] | not verified on Mac | no Swift SDK | Apache-2.0, gated download | 2.25 GB |
| Qwen3-ASR 1.7B | FLEURS 12.50 (Q8) [B] | — | — | third-party MLX | Apache-2.0 | 2.0 GB |
| Voxtral Mini 3B | no Polish [L] | — | — | — | Apache-2.0 | ~9.5 GB |
| Apple `SpeechTranscriber` | Polish not supported [M][N] | — | — | native | system | — |

Polish WER numbers from different sources are not directly comparable. On the one benchmark that
measures all of them the same way [B], Polish accuracy goes Whisper large-v3 (4.69) > large-v3-turbo
(5.81) > Cohere (6.15) ≈ Parakeet Ultra (6.16) > Parakeet v3 (7.37): Ultra closes most of the gap
to Whisper turbo but does not beat it.

Local dictation apps ship the same two families: VoiceInk offers Parakeet V2/V3/Ultra and Whisper
large-v3/turbo and starts users on Parakeet [J][O]; superwhisper offers Whisper and Parakeet [O].

**Known risk of Parakeet: language drift.** Parakeet has no language token, so the output language
cannot be pinned [P]. On spontaneous French interviews, v3 put English into 31% of utterances (0% on
read speech) [Q]. Polish and Ultra were not tested. NVIDIA trained the tokenizer to allow
code-switching [A], which suits English terms inside Polish sentences, but whole phrases may flip.
Whisper can pin the language (`pl`/`en`) but has documented looping and repetition hallucinations
on long audio [S], which the VAD segmentation in the spec already limits (segments, not 5-minute
windows).

## Decision

1. **Default engine: Parakeet Ultra through FluidAudio** (`parakeet-ultra`, CoreML weights from
   `FluidInference/parakeet-ultra-coreml`, revision pinned in `ModelCatalog`). It is a drop-in for
   v3 in the same SDK, is the most accurate Parakeet for Polish (within ~0.4 WER points of Whisper turbo on [B]) and
   runs over 100× real time, which matters more for live segment transcription.
2. **Second engine: Whisper large-v3-turbo through WhisperKit, with the language pinned** (Settings:
   „Polski” / „English”). It ships in Phase 1 (step 1.10) instead of waiting for a spike, because
   language drift is documented for spontaneous non-English speech and the user dictates exactly
   that. If Parakeet flips to English, the user switches the engine in Settings; both stay behind
   the `SpeechEngine` port.
3. Rejected: Whisper large-v3 (best Polish WER, but much slower and turbo is close), Canary (no
   Apple-silicon port), Cohere Transcribe (gated download, no Swift path, unverified on Mac),
   Qwen3-ASR and Voxtral (weak or no Polish), Apple `SpeechTranscriber` (no Polish).

## Consequences

- New dependency next to FluidAudio: WhisperKit (MIT), pinned exactly. Both engines' weights are
  data files (`.mlmodelc`) downloaded through `ModelManager` from the Hugging Face allowlist.
- Attribution for CC-BY-4.0 weights in Settings and `THIRD_PARTY_NOTICES.txt`.
- What the spike would have measured on the user's voice (language-drift rate, WER on mixed speech)
  is now checked by dogfooding during the Phase 1 QA; the result is added to this ADR.
- The technical checks from the spike (offline model loading, strict concurrency, hardened runtime,
  pasteboard timing, memory) move into the acceptance tests of Phase 1 steps.

## Sources

- [A] https://arxiv.org/pdf/2509.14128 (Tables 5, 11, 12; §4.1)
- [B] https://models.handy.computer/languages/pl (FLEURS, Q8_0)
- [C] https://huggingface.co/moondream/parakeet-ultra
- [D] https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- [E] https://github.com/FluidInference/FluidAudio, https://docs.fluidinference.com
- [G] https://huggingface.co/argmaxinc/whisperkit-coreml
- [I] https://docs.cohere.com/docs/transcribe
- [J] https://tryvoiceink.com/docs/local-models
- [L] https://huggingface.co/mistralai/Voxtral-Mini-3B-2507
- [M] https://developer.apple.com/forums/thread/797835
- [N] https://blog.addpipe.com/apple-speechanalyzer-api/
- [O] https://lumevoice.com/blog/voiceink-vs-superwhisper/, https://spokenly.app/blog/superwhisper-review
- [P] https://github.com/NVIDIA-NeMo/Speech/discussions/14620
- [Q] https://thoth-app.com/blog/2026-05-19-parakeet-language-drift/
- [S] https://arxiv.org/pdf/2508.15882
