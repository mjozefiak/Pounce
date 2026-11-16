# Meeting notes: state-of-the-art techniques for an on-device PL/EN product (research B)

Date: 2026-11-13. All URLs were accessed on 2026-11-13 unless a different date is given.

## How to read this report

Every claim carries one of these labels:

- **FACT**: read today in a primary source (paper, model card, vendor documentation, repository file). The URL follows.
- **SECONDARY**: read today, but in a blog, aggregator, law-firm note or search-result summary. Treat as a lead, not as proof.
- **PRIOR**: from my own knowledge of a well-known paper or model card, not re-fetched today. Check before quoting.
- **INFERENCE**: my conclusion from the facts.
- **UNVERIFIED**: I could not confirm it.

Limits of this research:

- The AMU Polish ASR leaderboard (BIGOS/PELCRA live numbers) renders dynamically and could not be read. Polish numbers for 2025-2026 models on BIGOS/PELCRA are therefore missing.
- No published Polish-English code-switching ASR benchmark was found.
- No published figure was found for: Whisper large-v3-turbo Polish WER from a primary source, Apple SpeechTranscriber quality in Polish (Polish is not supported), diarization DER on system-audio mixes with codec artefacts, LLM name-inference error rate on meetings, action-item precision/recall on a shared public protocol, llama.cpp tokens/s for the listed models measured directly on M4-class Macs.
- Nothing here is legal advice.

---

## 0. Competitive context that changed in the last four months

- **FACT**: Anthropic announced **Claude Meetings (beta) on 2026-11-12**. Claude joins the call as a *visible participant* and posts a notice in the chat. It saves transcript, summary and screen descriptions, not audio. Google Meet only for now. Team and Enterprise plans only. It answers questions in chat, uses connected tools and builds documents live. By default it stays out of calls with outside invitees. Partner integrations (Gong, Granola, Otter) for sending transcripts elsewhere are "coming soon". The article names no supported languages. https://claude.com/resources/articles/claude-meetings
- **INFERENCE**: Claude Meetings is a bot, cloud-only, Google-Meet-only, business-plan-only product. A local, bot-less recorder that works in every app, in person, offline and for individuals does not overlap much with it. The gap to attack is: any app, private by construction, Polish quality, and the user's own archive.
- **FACT**: **Chamberlain v. Granola, Inc.**, No. 3:26-cv-07926 (N.D. Cal., 2026-07-30). The complaint attacks exactly the bot-less design: no notice to other participants, marketing that others "won't know it's there", chat notice and watermark off by default, training on user data by default. Claims: ECPA, CIPA §631 and §632, Cal. Penal Code §502, UCL, intrusion upon seclusion, unjust enrichment. Allegations only; no ruling. https://btlaw.com/en/insights/alerts/2026/what-the-granola-class-action-means-for-companies-building-and-deploying-conversation-capture-tools
- **INFERENCE**: an on-device product has a real answer to two of the three attack lines (no vendor receives the audio or text, no training on it). It has no automatic answer to the third (other participants are not told). See section 6.

---

## 1. ASR quality for Polish on-device

### 1.1 Published Polish WER (read speech)

| Model | FLEURS pl | MLS pl | Source |
|---|---|---|---|
| Whisper large-v3 | 4.74 | 8.88 | NVIDIA paper, Tables 11-12 |
| Canary-1B-v2 | 6.64 | 8.77 | same |
| Parakeet-TDT-0.6B-v3 | 7.31 | 7.28 | same, and model card |
| seamless-m4t-v2-large | 8.76 | 5.74 | same |
| seamless-m4t-medium | 14.84 | 10.22 | same |

- **FACT**: table above from arXiv 2509.14128 (Canary-1B-v2 & Parakeet-TDT-0.6B-v3), appendix tables. https://arxiv.org/html/2509.14128v1
- **FACT**: Parakeet-TDT-0.6B-v3 model card: released 2025-08-14, CC-BY-4.0, 25 European languages including Polish, automatic language detection, word and segment timestamps, Polish FLEURS 7.31 and MLS 7.28, no CoVoST Polish row, no statement about code-switching. Full attention up to 24 minutes, local attention up to 3 hours. WER computed without punctuation and capitalisation. https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- **FACT**: FluidAudio's CoreML port of Parakeet v3 measures **Polish FLEURS 8.6% WER, 2.8% CER, 190x real time** on an M4 Pro (macOS 26). English 5.4%, average over 24 languages 14.7%. So the CoreML conversion costs roughly 1.3 points on Polish against NVIDIA's 7.31. https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md
- **FACT**: The Open ASR Leaderboard paper's multilingual track covers German, French, Italian, Spanish and Portuguese only. It has no Polish column. https://arxiv.org/html/2510.06961v4 (SECONDARY reading through search summary)
- **No published figure found** for Whisper large-v3-turbo on Polish from a primary source. **SECONDARY**: a vendor blog reports 5.32% FLEURS pl for large-v3-turbo and 12.78% for Qwen3-ASR-1.7B on its own run. https://whispernotes.app/blog/qwen3-asr-vs-whisper

### 1.2 Published Polish WER (spontaneous speech: this is what meetings look like)

- **FACT** (BIGOS V2, NeurIPS 2024 Datasets & Benchmarks, Table 2):

| Dataset | Speech | Systems | Median WER | Mean WER |
|---|---|---|---|---|
| BIGOS V2 | read | paid | 12.96 | 17.26 |
| BIGOS V2 | read | free | 15.47 | 21.93 |
| PELCRA | spontaneous | paid | 29.90 | 31.34 |
| PELCRA | spontaneous | free | 34.18 | 37.45 |

  The paper states read speech is better than conversational speech by about 17-19 points for the same systems. On PELCRA, whisper_large_v3 scores 28.5-35.1% WER across age groups (Table 21); nemo_multilang scores 38.6-53.6%. Manual inspection found Whisper more prone to hallucination at extreme speech rates. https://papers.nips.cc/paper_files/paper/2024/file/69bddcea866e8210cf483769841282dd-Paper-Datasets_and_Benchmarks_Track.pdf
- **FACT** (Samsung R&D Poland, PolEval 2024, arXiv 2410.22903, Table 3, dev-0):

| Model | BIGOS | PELCRA | Total |
|---|---|---|---|
| whisper-large-v3, no fine-tuning | 6.08 | 29.04 | 21.39 |
| fine-tuned on 669 h | 6.16 | 23.35 | 17.62 |
| + 1,330 h synthetic | 3.93 | 20.98 | 15.30 |

  https://arxiv.org/html/2410.22903v1
- **INFERENCE**: the honest planning number for Polish meeting speech is **20-30% WER for the best open models**, not the 5-8% seen on FLEURS. Fine-tuning Whisper on Polish conversational data moves PELCRA from 29 to 21. Nothing published shows where Parakeet v3 sits on PELCRA. This is the single most important measurement the project must make itself.

### 1.3 Other engines: what supports Polish at all

| Engine | Polish? | Evidence |
|---|---|---|
| Apple SpeechAnalyzer / SpeechTranscriber (macOS 26) | **No** | SECONDARY: 42 locales, 22 languages as of 2026-08; Polish, Czech, Ukrainian, Greek, Hindi listed as absent. English-only benchmark: 2.12% / 4.56% LibriSpeech clean/other on M2 Pro. https://loronote.com/en/blog/apple-speechanalyzer-vs-whisper . Confirm by calling `SpeechTranscriber.supportedLocales` on the target OS. |
| Voxtral Mini 3B / Small 24B (2025-07) | **No** (8 languages) | SECONDARY via search of Mistral pages; NVIDIA's paper has no Polish row for Voxtral-Mini-3B. |
| Voxtral Mini Transcribe V2 / Voxtral Realtime 4B (2026-02) | **No** (13 languages; Russian yes, Polish no) | FACT for the Realtime paper's language set and averages: arXiv 2602.11298. SECONDARY: users report Polish recognised as Russian. https://arxiv.org/html/2602.11298v2 , https://news.ycombinator.com/item?id=46886735 |
| Canary-Qwen-2.5B | English only | PRIOR (model card not re-fetched) |
| Kyutai STT (stt-1b-en_fr, stt-2.6b-en) | **No** | SECONDARY: English and French only. https://kyutai.org/stt |
| Moonshine v2 / Flavors of Moonshine | **No Polish found** | SECONDARY: Arabic, Chinese, Japanese, Korean, Ukrainian, Vietnamese flavours. arXiv 2509.02523, 2602.12241 |
| Qwen3-ASR 0.6B / 1.7B (2026-01, Apache-2.0) | UNVERIFIED in the official list | arXiv 2601.21337; only a third-party Polish number (12.78% FLEURS) |
| NVIDIA **Nemotron 3.5 ASR Streaming 0.6B** (2026-06-04, OpenMDW-1.1) | Yes, "broad-coverage" tier | FACT: Polish FLEURS 15.15% at 1.12 s latency with language ID given, 19.88% at 80 ms; auto-detect 16.55% at 1.12 s. Worse than Parakeet v3 offline. https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b |
| NVIDIA **Nemotron-Labs-Unified-ASR-0.6B** (2026-10-27, OpenMDW-1.1) | Yes (25 European languages) | FACT: Polish 6.01 offline, 7.09 at 1.12 s, 7.84 at 0.56 s, 9.27 at 0.32 s, 11.89 at 0.16 s (average over the available FLEURS/MCV/MLS sets). Takes a language-ID prompt. One model for offline and streaming. https://huggingface.co/nvidia/nemotron-labs-unified-asr-0.6b |

- **INFERENCE**: for Polish the on-device field is still Parakeet v3, Canary-1B-v2, Whisper large-v3(-turbo), and now Nemotron-Labs-Unified. The unified model matters for three reasons: it is the newest Polish-capable NVIDIA release, it has a **language-ID prompt** (Parakeet v3 has none), and it streams at 0.56-1.12 s with only 1-2 points lost. FluidAudio already benchmarks an English "Parakeet Unified" and a "Nemotron Multilingual" CoreML build (FACT, Benchmarks.md above), so a CoreML path probably exists or is near. UNVERIFIED whether the multilingual unified model is already in FluidAudio.

### 1.4 Known failure modes

- **Parakeet v3 has no language control.** FACT: an NVIDIA maintainer states the model does not output or accept a language (NeMo issue 15097). SECONDARY: user reports of Spanish dictation coming back in English, Russian transliterated with Polish diacritics, short Polish utterances misrecognised with Czech-like spellings, and the model settling on a language only after the first sentences. https://github.com/NVIDIA-NeMo/Speech/issues/15097 , https://github.com/anomalyco/hex/issues/948 , https://github.com/cjpais/Handy/issues/2406
- **INFERENCE**: for PL speech with EN terms this is two-edged. With no language lock the model can emit English words inside Polish speech. It can also drift into the wrong language on short segments, which is exactly what VAD-cut meeting turns are ("okay", "tak, deploy jutro"). Mitigation: avoid very short isolated segments (merge adjacent VAD segments to at least a few seconds of context), and flag segments whose output language differs from the meeting's dominant language for a second pass.
- **Whisper hallucinates on non-speech.** FACT: arXiv 2501.11378 (large-v3: silence-padded speech and non-speech both trigger hallucination and looping; lower beam size helps; the hallucination-silence threshold helps only slightly). FACT: arXiv 2505.12969 reports large-v3 hallucinating on 99.97% of UrbanSound8K clips against 13.52% for Conformer-CTC-large. https://arxiv.org/pdf/2501.11378 , https://arxiv.org/pdf/2505.12969v1.pdf
- **INFERENCE**: never feed Whisper un-gated audio. VAD first, drop no-speech segments, and treat Whisper output on low-energy segments as suspect. NVIDIA trained Parakeet/Canary with 36,000 h of non-speech with empty targets (FACT, arXiv 2509.14128), so the transducer is the safer first engine.
- **Code-switching.** No Polish-English benchmark exists (search today). FACT: NVIDIA justifies the unified tokenizer partly by code-switching but reports no metric. Related work uses **PIER** (point-of-interest error rate: errors on the embedded-language words only) next to WER, for example CSFleurs and MUSCAT (arXiv 2604.15929, SECONDARY). INFERENCE: adopt PIER on English terms as the project's own code-switching metric.

### 1.5 Mitigation techniques with evidence

1. **Vocabulary / hotword biasing.** FACT: FluidAudio ships CTC-based vocabulary boosting for the batch path: the TDT encoder transcribes, a Parakeet CTC 110M encoder spots keywords, default context-biasing weight 3.0. Not available for streaming. Reported on Earnings22: vocabulary recall 85.2%, precision 99.3% (single run). https://docs.fluidinference.com/asr/custom-vocabulary . UNVERIFIED: whether the 110M CTC spotter is English-only; if so, it will help English tech terms inside Polish speech (the exact case) but not Polish names. Test this first.
2. **LLM post-correction with a glossary.** FACT: generative error correction is an established line (HyPoradise, arXiv 2309.15701). FACT: text-only correction over-corrects; adding N-best lists and phonetic context helps rare words (arXiv 2505.17410). One practical guard from the literature: fall back to the ASR output when the corrected text differs from it by more than three words (arXiv 2505.16212). No Polish study found. INFERENCE: constrain the corrector to *replace spans with glossary entries only* (names from calendar attendees, project terms, user jargon), give it phonetic near-matches, and keep the raw transcript beside the corrected one. Never let it rewrite freely.
3. **Second engine on low-confidence segments.** INFERENCE from 1.1-1.4: Parakeet first (fast, no hallucination on silence), then Whisper large-v3-turbo with `language=pl` pinned on segments that are low-confidence, in the wrong language, or contain out-of-vocabulary-looking tokens. Whisper has the best Polish read-speech WER (4.74 vs 7.31) and accepts a language pin and an initial prompt with the glossary. No published figure exists for this exact cascade on Polish.
4. **ROVER / consensus of two engines.** PRIOR: ROVER (Fiscus 1997) reduces WER when systems make different errors. No Polish or Parakeet+Whisper figure found. INFERENCE: full ROVER doubles compute and needs word-level confidences from both engines; the selective cascade in point 3 buys most of the gain for a fraction of the cost. Use disagreement between engines as the *confidence signal* shown in the UI and passed to the summariser.
5. **Polish fine-tunes.** FACT: fine-tuning large-v3 on Polish data took PELCRA from 29.04 to 20.98 (1.2). INFERENCE: a Polish conversational fine-tune of large-v3-turbo converted to WhisperKit is the highest-ceiling option for the second engine, but it is a training project, not a configuration change.

### 1.6 Real-time factors on Apple silicon

- **FACT** (FluidAudio Benchmarks.md): Parakeet v3 CoreML about 190-210x real time on FLEURS (M4 Pro); 110-156x on LibriSpeech; 335x on 60-minute audio on M5 Pro (ANE). Parakeet Unified streaming 29x, batch 123x (M5 Pro). Offline diarization 64-122x (M5 Pro class).
- **FACT**: WhisperKit paper (arXiv 2507.10860) reports 0.46 s latency on-device with accuracy matching server systems, English. https://arxiv.org/html/2507.10860v1
- **SECONDARY**: WhisperKit large-v3-turbo about 12x real time on M2 Pro (argmax benchmark space entry); 0.084 RTF on M5 Pro (third-party). No single trusted table found.
- **INFERENCE**: a one-hour meeting is about 20-30 s of Parakeet work and 3-6 minutes of Whisper-turbo work. A selective second pass over 10-20% of the audio costs well under a minute.

---

## 2. Diarization on-device

### 2.1 Published DER

**FACT**: pyannote model card, no collar, overlap scored. https://huggingface.co/pyannote/speaker-diarization-community-1

| Benchmark | 3.1 | community-1 | precision-2 (cloud) |
|---|---|---|---|
| AMI IHM | 18.8 | 17.0 | 12.9 |
| AMI SDM | 22.7 | 19.9 | 15.6 |
| AliMeeting ch1 | 24.5 | 20.3 | 15.2 |
| DIHARD 3 full | 21.4 | 20.2 | 14.7 |
| VoxConverse v0.3 | 11.2 | 11.2 | 8.5 |
| CALLHOME part 2 | 28.5 | 26.7 | 16.6 |
| MSDWild | 25.4 | 22.8 | 17.3 |

community-1 is CC-BY-4.0, runs offline, and adds "exclusive" diarization (one speaker per instant), which makes joining with ASR word timestamps simpler. Components cited: powerset segmentation, WeSpeaker embeddings, VBx clustering.

**FACT**: NVIDIA Streaming Sortformer v2.1 model card. https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1

| Latency | AMI IHM | AMI SDM | AliMeeting far | DIHARD3 ≤4 spk | DIHARD3 ≥5 spk | NOTSOFAR1 ≥5 spk |
|---|---|---|---|---|---|---|
| 30.4 s | 15.90 | 17.80 | 13.55 | 14.84 | 38.90 | 34.81 |
| 1.04 s | 16.67 | 20.57 | 15.60 | 15.09 | 41.42 | 36.76 |

Maximum 4 speakers; "performance degrades on recordings with 5 and more speakers". Trained mainly on English. NVIDIA Open Model License. The card announces **Nemotron-3-Diarization** (8 speakers) as the successor.

- **SECONDARY**: Nemotron 3 Diarization: about 100M parameters, streaming and offline, up to 8 speakers, OpenMDW-1.1 for the main checkpoint, 12.73% DER on DIHARD III offline. AMI figure not confirmed. https://the-decoder.com/nvidia-drops-a-free-100m-parameter-model-that-identifies-up-to-eight-speakers-in-real-time/
- **SECONDARY**: DiariZen-Large-s80 (BUT): AMI-SDM about 14.0, DIHARD3 14.5, VoxConverse 9.1-9.2, NOTSOFAR-1 16.7-17.9 without collar. Weights reported as CC-BY-NC (non-commercial): verify before any use. Slower than pyannote (RTF 20 vs 45 in arXiv 2509.26177).
- **FACT**: independent benchmark arXiv 2509.26177: PyannoteAI (commercial) 11.2% overall, DiariZen 13.3%. **Missed speech is the dominant error for all models, especially on meeting data, followed by speaker confusion.** Segments under 0.5 s cause under 5% of missed speech; most errors are onset/offset timing. All Sortformer variants degrade beyond four speakers. https://arxiv.org/html/2509.26177v1

### 2.2 What FluidAudio actually ships

**FACT** (Benchmarks.md, link above):

- Offline and online pipelines both use **community-1** (segmentation + WeSpeaker embedding + VBx), converted to CoreML, embeddings in fp16 on the Neural Engine with some precision loss.
- Offline, AMI-SDM, 16 meetings, M5 Pro: 10.6% DER with the in-repo scorer (collar 0.25); under pyannote's protocol (no collar, overlap scored) **18.3-20.3% with overlapping output, 23.1-24.2% with exclusive output**, against 17.0-19.9 published. VoxConverse 13.9-15.1% average.
- **Online (streaming) clustering pipeline: 38-56% DER on AMI-SDM.** Not usable for final labels.
- Sortformer CoreML: streaming 26.4-31.7% DER on AMI-SDM, 835x real time; whole-file offline mode 56.7%.
- LS-EEND: 20.7% DER on AMI-SDM, CPU only, more false alarms.
- CAM++ speaker embedding: within-meeting EER 2.85%, across meetings 3.55%.
- **INFERENCE**: (a) live speaker labels will be visibly worse than final ones; the product should re-diarize offline after the meeting and replace the live labels. (b) "Exclusive" output costs about 4 points on AMI because overlap is discarded; use overlapping output for scoring and exclusive output only for word assignment. (c) The 4-speaker cap of Sortformer is a hard product limit for group calls; the clustering pipeline has no cap.

### 2.3 Failure modes and the dual-channel advantage

- Published: overlap, more than 4 speakers (Sortformer), missed speech at turn boundaries, non-English degradation for Sortformer (2.1).
- **No published DER found** for remote speakers mixed into one system-audio stream with codec artefacts (Opus/AAC, noise suppression, automatic gain). INFERENCE: this is harder than AMI for embeddings (codec and per-participant noise suppression flatten voice differences) but easier for segmentation (meeting apps mostly forward one active speaker at a time, so overlap is rarer). Must be measured on real recordings.
- **Dual channel.** INFERENCE: microphone = "me" removes one speaker from the clustering problem and gives a 100% reliable label for the user, *if* the remote audio does not leak into the microphone. With loudspeakers it leaks. Two consequences: the microphone transcript duplicates remote speech, and remote voices are attributed to "me".
- **Echo handling in the wild.** SECONDARY (GitHub projects found today): the common design is a process tap of system output used as the reference for WebRTC AEC3 on the microphone (ClearCall, Loopbacker, Speecher). Apple's voice-processing I/O is the alternative, but it ducks other apps' audio and can treat system audio routed through the same engine as echo. anarlog (formerly Hyprnote/Char) has its own AEC crate; one project uses a neural AEC (DTLN-aec). https://github.com/MiantGV/ClearCall , https://github.com/fastrepl/anarlog
- **INFERENCE**: keep three defences in order: (1) detect headphones and skip suppression; (2) reference-based echo suppression on the microphone; (3) a text-level guard: drop microphone segments that overlap in time with a system segment and whose words match it. The repository already has an echo suppressor and timeline alignment; the text-level duplicate guard is the cheap last line.

### 2.4 Speaker naming

| Method | Evidence | Assessment |
|---|---|---|
| Meeting-app UI through Accessibility | SECONDARY: Granola's Zoom speaker tags use the macOS Accessibility permission to read display names and the active-speaker indicator from the Zoom desktop app; Google Meet names come through a browser extension; overlapping speech and shared room devices still give wrong or missing names. FACT: Granola docs confirm speaker tags for Meet, Zoom, Teams on macOS/Windows and "Me/Them" otherwise. https://docs.granola.ai/help-center/taking-notes/transcription , https://zackproser.com/blog/granola-zoom-integration-guide | Highest-value source: it gives real names with timestamps. Fragile (UI changes), needs Accessibility permission, per-app adapters. Use it as *weak supervision*: align active-speaker intervals with diarization clusters and name a cluster only when overlap is consistent. |
| Calendar attendees (EventKit) | No accuracy study found. | Gives the candidate name list, never the mapping. Use to constrain every other method and as the correction glossary. |
| LLM inference from transcript | FACT: text-based speaker naming, arXiv 2407.12094: best model 80.3% precision, 50.0% recall. FACT: training-free identity-aware LLM refinement exists (arXiv 2509.15082); no name accuracy seen. SECONDARY: text-only attribution defaults to the target speaker when ambiguous (arXiv 2609.20232). | Low recall, non-trivial error. Use only as a *suggestion* the user confirms, and only from explicit evidence ("Dzięki, Aniu" followed by a speaker change). Never auto-apply. |
| Persistent voiceprints | FACT: FluidAudio `SpeakerManager`: cosine distance threshold 0.65 for a match, 0.45 for updating an embedding, 1.0 s minimum speech; `upsertSpeaker`, permanent speakers. CAM++ across-meeting EER 3.55%. https://docs.fluidinference.com/diarization/speaker-manager | Works technically. Legal exposure below. |

**Legal status of voiceprints.**

- **FACT**: EDPB Guidelines 02/2021 on virtual voice assistants: processing voice to uniquely identify a person is biometric data under Art. 9 GDPR and needs an Art. 9 derogation, in practice explicit consent of the identified person. https://www.edpb.europa.eu/system/files/2021-07/edpb_guidelines_202102_on_vva_v2.0_adopted_en.pdf
- **SECONDARY**: Fireflies.ai faces BIPA suits in Illinois (*Cruz v. Fireflies.AI Corp.*, 3:25-cv-03399) alleging its speaker recognition creates voiceprints of participants without written consent; a similar BIPA theory is pleaded against Otter. https://tldv.io/blog/ai-meeting-recorder-lawsuits/
- **INFERENCE**: diarization inside one recording (anonymous "Speaker 2") is not identification. A stored embedding matched across meetings to a named person is. Safe design: the user's *own* voice enrolled with explicit consent; other people's voiceprints off by default, per-person opt-in, stored only locally and encrypted, deletable, never synced, never sent to an external AI provider, with a plain statement that the user is responsible for the other person's consent. Consider not offering cross-meeting voiceprints for others at all in v1; names from the meeting UI and calendar cover most of the value without biometrics.

---

## 3. Notes generation

### 3.1 How Granola does it

- **FACT**: inputs are the transcript, the user's raw notes and calendar event data. Enhancement runs automatically when the call ends. The user's notes are shown in black. A magnifying glass beside each enhanced line opens the transcript or raw-note passage it came from. Templates (built-in and custom, each with its own prompt and structure) control the output; the note can be regenerated with another template. "Granola uses a mix of models, mainly from OpenAI and Anthropic." Edits to one note do not affect future notes. https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes
- **FACT**: audio goes "directly from your microphone and system audio to our transcription provider"; no audio is stored; there is a jargon list in language settings. https://docs.granola.ai/help-center/taking-notes/transcription
- **SECONDARY**: Recipes are saved prompts run after enhancement from the chat bar (follow-up email, action items). Chat was rebuilt in April 2026 as an agentic search over months of notes with citations. **Briefs** (May 2026): a short cited rundown before external meetings, built overnight from past notes, optional Gmail and public web; not generated for internal-only meetings. People and Companies directories are built from meetings. https://docs.granola.ai/help-center/getting-more-from-your-notes/recipes , https://docs.granola.ai/help-center/taking-notes/pre-meeting-briefs
- **INFERENCE**: Granola's quality comes from three things that are not model size: (1) the user's own notes steer what matters; (2) every line links back to its source; (3) templates per meeting type. All three can be built locally. Granola's weaknesses for this product's users: cloud transcription, Polish not documented, no audio kept so nothing can be re-transcribed later with a better model.

### 3.2 Research on summarisation strategy

- **FACT**: hierarchical merging handles inputs longer than the context but is often unfaithful; adding retrieved or extractive source context at each merge step improves faithfulness (Llama 3.1 models). arXiv 2502.00977. https://arxiv.org/pdf/2502.00977
- **FACT**: long-context summarisation shows positional bias for faithfulness (lead and lost-in-the-middle); the end of the context is summarised more faithfully. arXiv 2410.23609 (NAACL 2025). https://arxiv.org/html/2410.23609
- **FACT**: FRAME (Findings of EMNLP 2025) recasts meeting summarisation as extract-facts, organise, then write; it reports lower hallucination and omission on QMSum and FAME. https://aclanthology.org/2025.findings-emnlp.1094.pdf
- **PRIOR**: Chain of Density (Adams et al., arXiv 2309.04269) iteratively adds missing entities at fixed length; human preference peaks at a middle density step, not the densest.
- **FACT**: ASR noise: task models tolerate a certain amount of transcription noise; WER does not predict downstream impact; error type matters (ENDOW, arXiv 2502.13645, ACL 2025). SECONDARY reading of the same paper: at WER ≤ 0.2 the effect on QMSum summarisation was small for all models tested. PRIOR/SECONDARY: Minuteman (arXiv 2309.05272) found most damaging ASR errors are named entities. https://arxiv.org/pdf/2502.13645
- **No published head-to-head found** of map-reduce against single-pass long context for 4-12B local models on meeting transcripts.

**INFERENCE: recommended pipeline for a local 4-12B model.**

1. **Prepare**: speaker-attributed transcript, merged turns, timestamps every turn, low-confidence spans marked, glossary and attendee names in the prompt.
2. **Segment by topic** (not by fixed token count): split on long pauses, speaker-pattern changes and lexical shift; target 1,500-3,000 tokens per segment with a one-turn overlap.
3. **Map: extract, do not summarise.** Per segment, emit structured JSON through llama.cpp grammar-constrained output: decisions, action items (owner, task, due date *as said*, quote, turn id), open questions, facts and numbers, each with the id of the supporting turn. Extraction is the step small models do well; free abstraction is where they hallucinate.
4. **Verify each item** against its cited turn: the cited turn must exist and must contain the named entities and numbers of the item (string and fuzzy match; a small NLI or the same LLM as judge for the rest). Drop or mark what fails. This is the hierarchical-merging-with-source-context finding applied.
5. **Reduce**: write the note from the verified items plus the user's own notes, using the template for the meeting type. The user's notes define section headings and emphasis (Granola's lesson). Every bullet keeps its turn ids so the UI can jump to the transcript and play the audio.
6. **Single-pass mode** when the whole transcript fits comfortably (short meetings, or a 32K-128K context model): still require turn-id citations and run step 4. Put the instructions and the user's notes at the *end* of the prompt (positional-bias finding).
7. **Dates**: resolve "do piątku" against the meeting date in code, not in the model; store both the phrase and the resolved date.
8. **Names in Polish**: owners appear inflected ("Ani", "Tomkowi"). Map to the nominative from the attendee list in code or with an explicit prompt rule; this is a Polish-specific error source that English research does not cover.

The built-in advantage over Granola: because the audio is kept (encrypted spool), a low-confidence span cited by a decision can be re-transcribed with the second engine *before* the note is written.

### 3.3 Action items and decisions: accuracy evidence

- **No shared public protocol found** that scores owner and due date. Reported F1 ranges from about 0.6 to 0.96 across self-reported, mostly synthetic sets (SECONDARY, GitHub projects). An AWS post reports LLM-judged faithfulness 0.83 for its best model on action items, without precision/recall. https://aws.amazon.com/blogs/machine-learning/meeting-summarization-and-action-item-extraction-with-amazon-nova/
- **INFERENCE**: build your own scorer (section 4). Expect the typical errors: implied commitments missed (recall), suggestions promoted to commitments (precision), wrong owner when the speaker assigns a task to someone else, hallucinated dates.

### 3.4 Local models for Polish, 4-12B

**FACT**: Bielik 11B v3 paper, arXiv 2601.11579 (2026-01). Architecture: Mistral-7B-v0.2 scaled to 50 layers, 11.2B parameters, native context 32,768, YaRN-extended to 131,072. https://arxiv.org/pdf/2601.11579

Open PL LLM Leaderboard, instruction models, 5-shot (Table 5), selected rows:

| Model | Params (B) | Average |
|---|---|---|
| Bielik-11B-v3.0-Instruct | 11.2 | 65.93 |
| Qwen3-32B | 32.8 | 64.24 |
| Mistral-Small-24B-Instruct-2501 | 24.0 | 62.97 |
| phi-4 | 14.7 | 62.57 |
| Qwen3-14B | 14.8 | 62.24 |
| gemma-3-12b-it | 12.0 | 62.20 |
| Bielik-4.5B-v3.0-Instruct | 4.8 | 56.13 |
| gemma-3-27b-it | 27.0 | 55.92 |
| Qwen3-8B | 8.2 | 55.78 |
| Qwen3-4B | 4.0 | 55.49 |
| Mistral-Nemo-Instruct-2407 | 12.2 | 55.27 |

CPTUB (Complex Polish Text Understanding, Table 7), overall: gemma-3-27b-it 3.81, Bielik-11B-v3.0 3.73, Mistral-Small-24B-2501 3.71, pllum-12b-nc-chat-250715 3.67 (non-commercial), Bielik-4.5B-v3.0 3.38, phi-4 3.30, PLLuM-12B-chat 3.14.

Caveat: these tables come from the Bielik team's own paper, and none of the benchmarks is a summarisation benchmark. **No published Polish summarisation benchmark for these models was found.**

| Model | Licence | Context | Notes |
|---|---|---|---|
| **Bielik 11B v3.0 / v3.1 Instruct** | Apache 2.0 (FACT, model cards); repositories are **gated** (accept terms with an HF account); v3.1 released around 2026-11-10 (SECONDARY) with tool-call and reasoning formats and a built-in system prompt of about 1,000 tokens that can be disabled (FACT). https://huggingface.co/speakleash/Bielik-11B-v3.1-Instruct | 32K native | Official GGUF repo for v3.0 (FACT: https://huggingface.co/speakleash/Bielik-11B-v3.0-Instruct-GGUF). Q4_K_M around 6.7 GB (INFERENCE from parameter count). Fits 16 GB Macs tightly, 24-32 GB comfortably. Gating means the app cannot download from the official repo without a token: needs a mirror agreement with SpeakLeash or a licence check on redistribution. |
| **Bielik 4.5B v3.0 Instruct** | Apache 2.0 | 32K per the technical report (arXiv 2505.02550); some distribution pages say 8K (SECONDARY conflict; check the GGUF metadata) | About 2.9 GB at Q4. The 16 GB default candidate. |
| **PLLuM 12B** | Split: `nc` variants CC-BY-NC-4.0 (not usable commercially), others Apache 2.0 (FACT: https://huggingface.co/CYFRAGOVPL/PLLuM-12B-nc-chat-2412) | no figure found | The better-scoring 2025-07 chat model is the non-commercial one. The Apache PLLuM-12B-chat scores below Bielik 4.5B on CPTUB. Not recommended. |
| **Gemma 3 12B / 4B** | Gemma terms of use (PRIOR) | 128K (PRIOR) | Strong multilingual, equal to Qwen3-14B and phi-4 on the Polish leaderboard at 12B. The long context allows single-pass on long meetings. Licence terms need review for a bundled catalogue. |
| **Gemma 3n E4B** | Gemma terms (PRIOR) | 32K (PRIOR) | Small-memory option; no Polish figure found. |
| **Qwen3 4B / 8B / 14B** | Apache 2.0 (PRIOR) | 32K native for small sizes (PRIOR) | Apache licence, good structured output; Polish score about 55-62. Disable thinking mode for extraction. |
| **Phi-4 14B** | MIT (PRIOR) | 16K (PRIOR) | Good Polish leaderboard score, short context, weak on CPTUB (3.30). |
| **Mistral Small 3.x 24B** | Apache 2.0 (PRIOR) | 128K (PRIOR) | About 14 GB at Q4: 32 GB Macs and up only. |

**Speed.** No trusted llama.cpp measurements for these exact models on M4-class chips were found. SECONDARY: on an M3 Pro through Ollama, qwen3:8b Q4_K_M 25.3 tok/s and gemma3:12b Q4_K_M 16.7 tok/s (https://localaimaster.com/blog/apple-silicon-ai-buying-guide). INFERENCE: an 11-12B model at 15-25 tok/s writes a 600-token note in 25-40 s, but the map step over a one-hour transcript (about 12-15K tokens in Polish) is dominated by prompt evaluation; expect several minutes end to end on a base M-series chip. Measure with `llama-bench` on the target Macs and put the numbers in `docs/perf.md`.

**INFERENCE: catalogue recommendation.** 16 GB: Bielik 4.5B v3 (Polish) or Qwen3-4B / Gemma 3 4B. 24-32 GB: Bielik 11B v3 as the Polish default, Gemma 3 12B as the long-context alternative. Decide by the project's own golden set (section 4), not by the leaderboard.

---

## 4. Evaluation

### 4.1 Metrics

| Layer | Metric | Source |
|---|---|---|
| ASR | WER and CER with a fixed Polish normaliser; **PIER** on English terms; entity recall for names and numbers | BIGOS normalisation study (1.2): normalisation alone moved WER by about 15 points, so freeze the normaliser |
| Diarization | DER (state collar and overlap rule every time), JER | pyannote card |
| ASR + diarization | **cpWER** and **tcpWER** (time-constrained), ORC-WER, with MeetEval | FACT: MeetEval, arXiv 2307.11394 https://arxiv.org/pdf/2307.11394 |
| Word-level speaker errors | WDER | PRIOR: Shafey et al., arXiv 1907.05337 |
| Summary faithfulness | Claim-level: split the note into atomic claims and check each against the transcript (FActScore style, PRIOR arXiv 2305.14251); NLI-based SummaC (PRIOR arXiv 2111.09525) and AlignScore (PRIOR arXiv 2305.16739); QA-based QAGS (PRIOR arXiv 2004.04228). All were built for English; for Polish use an LLM judge with the cited turn as evidence | FACT: long-context faithfulness metrics correlate better with humans when the source is chunked to about 1,024 tokens (arXiv 2410.23609) |
| Summary quality | LLM-as-judge rubric: faithfulness, coverage/omission, attribution correctness, structure, language correctness | FACT: MESA, "Is my meeting summary good?", arXiv 2411.18444; FACT: Evaluation-as-Search reports only moderate judge-human agreement on faithfulness (Spearman about 0.66), arXiv 2608.20392 |
| Action items / decisions | Precision, recall, F1 with three match levels: task only; task + owner; task + owner + date | own protocol (3.3) |
| Citations | Share of bullets whose cited turn supports them | own |

### 4.2 Datasets

- English: AMI, ICSI, QMSum (PRIOR arXiv 2104.05938), MeetingBank (FACT arXiv 2305.17529), ELITR Minuting Corpus (PRIOR, English and Czech), NOTSOFAR-1, AliMeeting (Mandarin).
- Polish speech: BIGOS V2 and PELCRA for BIGOS (DiaBiz phone dialogues, SpokesBiz, SpokesMix): transcripts, no summaries (FACT, 1.2).
- **LocalGovPL** (LREC 2026): 31,900 speaker-attributed Polish local-government session transcripts, 30 manually annotated for speaker attribution; no reference summaries. https://aclanthology.org/2026.lrec-1.626/
- **No Polish meeting corpus with reference summaries or action items was found.**

### 4.3 A private golden set and regression harness (INFERENCE)

- 20-30 real meetings with consent, 10-60 minutes: about half Polish with English terms, the rest English and mixed; 2 to 8 speakers; headphones and loudspeakers; Zoom, Meet, Teams, in person.
- Per meeting keep: both audio channels, a hand-corrected transcript with speakers, a list of English terms and names (for PIER and entity recall), a human reference note, gold decisions and action items with owner and date, and 5-10 question-answer pairs with the supporting turn (for ask-the-archive).
- Harness as a CLI test target, off by default like the existing real-model tests (environment variable for the data folder). Stages cache their output so one stage can change alone. Report: WER, PIER, entity recall, DER, cpWER, action-item F1 at three levels, citation support rate, judge scores, wall time, peak memory.
- Judge: a fixed, pinned prompt and model; a strong external model is acceptable here because the golden set is consented test data. Re-validate the judge against 50 human-rated claims whenever its model changes.
- Gate: no release if entity recall, action-item F1 or citation support drop beyond a set margin against the last accepted run.
- The repository already contains `Tests/MeetingsPluginTests/LibraryDiagnostics.swift` and a memory note about benchmarking engines on one real meeting. One meeting is an anecdote; 20 is a regression suite.

### 4.4 Vendor claims

- **SECONDARY**: published accuracy figures for Otter, Fireflies and Granola conflict (Otter 70% to 95% across sites; Fireflies 91% to "95%+"), come from competitors or aggregators, and never name the test set. No independent WER for Granola found. Granola itself publishes no accuracy number (FACT, its transcription page). Treat "95%" as clean-English marketing; BIGOS shows 30% WER for commercial systems on Polish conversation.

---

## 5. Ask-the-archive (local RAG)

### 5.1 Polish retrieval quality

**FACT** (PIRB, 41 Polish retrieval tasks, NDCG@10; figures as reported in arXiv 2609.12913 Table 1 and the original PIRB paper arXiv 2402.13350; read through search summaries, so confirm in the tables):

| Model | PIRB NDCG@10 |
|---|---|
| multilingual-e5-small | 50.65 |
| mmlw-retrieval-e5-small (Polish) | 52.34 |
| multilingual-e5-base | 53.12 |
| BGE-M3 | 55.75 |
| mmlw-retrieval-e5-base (Polish) | 56.09 |
| multilingual-e5-large | 57.29 |
| stella-pl-retrieval-8k (Polish) | 62.69 |

- **No PIRB figure found** for EmbeddingGemma or Qwen3-Embedding-0.6B. SECONDARY: MTEB multilingual v2 mean 61.15 (EmbeddingGemma, 308M parameters, 2K-token input, 768 dimensions truncatable to 128) and 64.33 (Qwen3-Embedding-0.6B, 32K context, 1,024 dimensions). FACT for the EmbeddingGemma paper's claims (best under 500M parameters, robust to truncation and 4-bit quantisation): arXiv 2509.20354.
- **FACT**: the PIRB paper's title result is that hybrid (dense + sparse) retrieval is a main subject of the benchmark; a 2026 paper reports small Polish-specific retrievers (PolDense) beating much larger multilingual models. https://arxiv.org/html/2402.13350v2 , https://arxiv.org/html/2609.12913v2
- **INFERENCE**: for a Polish-first archive, a small Polish-tuned retriever (mmlw-retrieval-e5-small/base: check licence and add the query/passage prefixes) or BGE-M3 is better supported by evidence than the newer general models. But PL/EN mixed text argues for a multilingual model. Decide on the golden-set questions (4.3).

### 5.2 Architecture (INFERENCE unless marked)

- **Start with FTS5 BM25 only.** The store already has `meeting_fts` with Polish folding. Add stemming-free prefix queries and query expansion by the LLM (inflected forms: "budżet, budżetu, budżecie"). Polish inflection is the main reason BM25 alone under-recalls; a dense channel fixes that.
- **Hybrid**: BM25 top 50 + dense top 50, fuse with reciprocal rank fusion, optionally rerank the top 20 (a Polish reranker exists: sdadas/polish-reranker family, PIRB 62.65 in the reranker category, SECONDARY; check the licence).
- **Chunks**: merge consecutive turns into windows of roughly 150-300 words that respect speaker-turn boundaries, with the speaker name, meeting title and date prefixed to the embedded text. Also embed the note's bullets (decisions, action items) as separate small chunks; they answer most questions.
- **Vector store**: at this scale brute force is enough. 1,000 meetings × about 60 chunks = 60,000 vectors × 384 float32 = 92 MB (23 MB as int8). A plain BLOB column and an Accelerate/vDSP scan over an in-memory matrix answers in milliseconds and needs no SQLite extension.
- **sqlite-vec with SQLCipher**: FACT: sqlite-vec is a dependency-free C extension with a static-link flag (`SQLITE_VEC_STATIC`) and a `SQLITE_CORE` mode; wrappers register `sqlite3_vec_init` through `sqlite3_auto_extension` or per connection. FACT: Zetetic says linking a second SQLite beside SQLCipher is unsupported. **UNVERIFIED**: sqlite-vec compiled against the SQLCipher amalgamation inside the GRDB wrapper package; nobody was found documenting it. INFERENCE: it should work if compiled into the same SQLite build (vec0 shadow tables are ordinary tables, so they would be encrypted with the file), but the repository pins an *unmodified* GRDB tag, so adding a C extension changes the build. Prefer encrypted BLOBs plus an in-memory scan; revisit sqlite-vec only past about one million vectors.
- **Answering**: retrieve, then answer only from the retrieved turns, with a citation (meeting, time, speaker) on every sentence; verify citations as in 3.2 step 4; say "not found in your meetings" when retrieval is weak. Granola's rebuilt chat exposes "citations and coverage" (SECONDARY): show which meetings were searched.
- **Cost**: embedding a one-hour meeting (about 60 chunks) with a 100-300M-parameter model takes seconds on Apple silicon (INFERENCE; no measured figure). Run it after note generation, at background priority, through the same lease that guards the LLM so only one model is resident.
- **Embeddings are derived personal data**: store them encrypted, delete them with the meeting, and version them by model id so a model change triggers re-embedding.

---

## 6. Live features, UX and the legal landscape

### 6.1 What vendors ship and users value

- Live transcript; notes during the meeting that steer the result; one-click template change (Granola, FACT 3.1).
- Pre-meeting **Briefs** with citations from earlier meetings with the same people (Granola, May 2026, SECONDARY). A local version: EventKit attendees → archive lookup by person → last decisions, open action items owed by and to the user.
- People and company pages built from meetings (Granola, SECONDARY).
- Recipes: saved prompts such as follow-up email (Granola, FACT that they exist).
- Live question answering during the call and live document building (Claude Meetings, FACT section 0).
- "Catch me up" (last N minutes) is cheap locally: summarise the rolling transcript since a timestamp; no retrieval needed. Use the streaming ASR output; mark it provisional.
- Export to Markdown/Obsidian: plain files with front matter (date, attendees, tags), wiki-links for people, and timestamps. No evidence needed; it is the lock-in answer.

### 6.2 Meeting start/stop detection

- **FACT**: Granola documents that auto-stop can fail for ad-hoc meetings and that back-to-back calls may merge when the microphone stays active. https://docs.granola.ai/help-center/taking-notes/transcription
- **SECONDARY**: `kAudioDevicePropertyDeviceIsRunningSomewhere` works for built-in and wired microphones but developers report Bluetooth microphones not reporting status; per-process attribution (`kAudioProcessPropertyIsRunningInput`, process object list) is Sonoma-era and has reported quirks. https://developer.apple.com/forums/thread/741026 , https://developer.apple.com/forums/thread/748257
- **INFERENCE**: combine signals and never start silently. Signals: a known meeting app's process is running input (per-process property) for more than a few seconds; a calendar event with a conferencing link is in progress; the meeting app's window title. Action: a notification "Meeting detected: record?" (one click), not an automatic start. Stop: input stopped for N seconds, or the calendar event ended and silence, with a "still recording" reminder. Split back-to-back meetings on calendar boundaries.

### 6.3 Consent and the legal landscape

- **United States**: federal ECPA is one-party consent; California (CIPA §631/§632) and about a dozen states require all-party consent. FACT: the Granola complaint and the law-firm analysis in section 0. FACT from the same analysis: the open question is whether the tool vendor is a "third-party eavesdropper" or a tool of the consenting user; the *Otter* ruling is expected to be the first on it. SECONDARY: one source reports the Otter motion to dismiss was granted in part and denied in part on 2026-08-13, with Otter treated as a possible third-party eavesdropper; verify on the docket.
- **INFERENCE**: a vendor that never receives audio or text is in the strongest position on the eavesdropper question: it has no capability to use the data. That advantage disappears the moment the optional external-AI path sends a transcript to a provider, so that path needs its own explicit, per-meeting-visible state.
- **Recommendations from counsel to builders** (FACT, btlaw link): review training-data defaults; design in-meeting notice (chat message, watermark, post-meeting notice) that gives a real chance to object; address non-user participants and all-party-consent jurisdictions; make deletion real.
- **Poland / EU**: SECONDARY (law-firm blogs, not UODO): recording a conversation you take part in is not the Art. 267 Criminal Code offence; using or publishing it is a separate matter (personal rights, GDPR). The voice and transcript are personal data; for business use the GDPR applies and participants should be informed. **No UODO position on AI notetakers was found.** INFERENCE: the user (or the employer) is the controller; a local-only app vendor is neither controller nor processor for the content. With the external provider path the *user* sends data to a provider under the user's own key and terms; the app must say exactly what leaves the Mac.
- **Product measures (INFERENCE)**: a visible recording indicator in the menu bar and a floating pill; a one-click "tell participants" action that pastes a notice into the meeting chat (default *on* for the first meetings, the opposite of Granola's default); a consent reminder in the first-run flow with a note about all-party-consent places; a per-meeting log line "notice sent at 10:02"; no stealth marketing language anywhere (the complaint quotes Granola's); easy deletion of a meeting including spool, transcript, embeddings and voice data; voiceprints of others off by default (2.4).

### 6.4 MCP: Claude as a client of the local archive

- **FACT** (Granola MCP docs): server at `https://mcp.granola.ai/mcp`, Streamable HTTP, OAuth 2.0 with dynamic client registration. Tools: `search_meetings`, `search_transcripts` (passages with timestamps), `list_meetings`, `get_meetings` (private and summarised notes, attendees), `get_meeting_transcript` (full or the section around a passage), `get_meeting_attachment`, `query_granola_meetings` (slower natural-language chat fallback), `list_meeting_folders`, folder write tools, `update_private_notes`, `list_templates`, `generate_summary`, `get_agent_brief` (role, priorities, people, projects, glossary), `get_account_info`. About 100 requests per minute. Free plan: last 30 days, no transcripts. https://docs.granola.ai/help-center/sharing/integrations/mcp
- **INFERENCE: local design.** A stdio MCP server (a small helper binary inside the app bundle that Claude Desktop / Claude Code launches) or a loopback Streamable HTTP server with a token. Read-only first: `search_meetings`, `search_transcripts`, `get_meeting` (note, decisions, action items), `get_transcript_section`, `list_people`, `list_open_action_items`. Return compact results with meeting id, time and speaker so Claude can cite. Important points:
  - The helper must not hold the SQLCipher key itself; it should ask the running app over XPC so that Keychain access stays with one signed binary and the app can show a per-client permission prompt and an access log.
  - Anything returned to a cloud model leaves the Mac. Treat MCP as part of the external-AI consent: off by default, per-client grant, optional "notes only, no transcripts" scope (Granola gates transcripts separately too), per-meeting "private" flag that MCP never returns.
  - Transcripts are untrusted text for the model that reads them (a participant can say "ignore previous instructions"). Return them as data, keep tools read-only by default.
  - Claude Meetings plans partner integrations for transcripts (section 0); being an MCP source positions the app as the user's private, all-apps archive that Claude can read.

---

## 7. Capture reliability

### 7.1 Process taps against ScreenCaptureKit

- **SECONDARY** (vendor engineering blog and Apple forum guidance summarised by search): Core Audio taps (`AudioHardwareCreateProcessTap`, macOS 14.2 for the API, 14.4 commonly cited as the practical minimum) capture everything including calls routed through daemons; ScreenCaptureKit may miss FaceTime/phone-call audio; taps need `NSAudioCaptureUsageDescription` and show a narrower "System Audio Recording Only" permission that reassures the user the screen is not captured; Apple's forum guidance is that for audio without screen a tap is the better choice. https://www.recall.ai/blog/how-to-get-access-to-system-audio , https://developer.apple.com/forums/thread/832345
- **INFERENCE**: taps are the right choice for this product (already chosen). Keep ScreenCaptureKit out; it adds the Screen Recording permission and its periodic re-consent prompts.

### 7.2 Known tap problems (all SECONDARY: GitHub issues and Apple forum threads found today)

| Problem | Evidence | Handling |
|---|---|---|
| **Format kept from the previous device after a route change**: built-in mic 48 kHz with a 24 kHz tap, or the reverse, gives AVAudioEngine error -10868; duplicate route notifications cause restart loops | https://github.com/moona3k/macparakeet/issues/481 | Rebuild tap *and* aggregate together; debounce and coalesce notifications; read the format after the rebuild, never cache it |
| **AirPods A2DP → HFP when the microphone opens**: output still reports 48 kHz while input is 24 kHz; a tap created in that window delivers zero buffers for the rest of the session; the default output device does not change, so default-device listeners never fire | https://github.com/scosman/Biscotti/issues/88 , https://github.com/scosman/Biscotti/pull/109 | Listen to *nominal sample rate* on the current devices, not only to default-device changes; create the tap after the microphone has started and the route has settled |
| **Silent zero buffers** while audio plays; restarting only the IOProc or only the aggregate is unreliable | https://developer.apple.com/forums/thread/825780 | Watchdog on sustained exact-zero buffers while a meeting process reports output; full teardown and rebuild |
| **Denied permission looks like silence**: a denied tap opens without error and delivers zeros | Meetily fork PRs (https://github.com/TylerBuza/Meetily-ActuallyFree/pull/12) | Self-test with a played probe sound at setup (the repository already has a self-test) |
| **No callbacks when nothing plays**: a tap-only aggregate is clocked by the output device; a stall watchdog then fires falsely | https://github.com/TylerBuza/Meetily-ActuallyFree/pull/51 | Distinguish "no callbacks" from "zero samples"; do not stop the recording on silence; timestamps from host time, not from sample counts |
| **Creating the aggregate triggers device-change notifications**, giving an infinite switch loop (macOS 15.7.2) | https://github.com/fastrepl/hyprnote/pull/1654 | Ignore notifications caused by your own aggregate/tap device; filter your tap device out of device lists |
| **`AudioHardwareCreateAggregateDevice` blocks** for seconds while the permission is undecided | https://github.com/contorch/meeting-capture/pull/33 | Create off the main thread with a timeout; the repository's "self-test hang" fix is the same class |
| **Level scales with channel count** on multi-output interfaces; very low volume reports | Apple forum posts via search | Mono or stereo mixdown tap; normalise level before VAD |
| **Tap rebuilt in bursts stalls `coreaudiod`** (volume keys lag) | https://github.com/deepratna-awale/open-wallpaper-engine-mac/issues/534 | Rate-limit rebuilds |
| Bluetooth HFP microphone quality (8-16 kHz band) | general | Suggest the built-in microphone when AirPods are the output: better ASR and no profile switch |

### 7.3 How open-source projects handle capture

- **anarlog (formerly Hyprnote, briefly Char)**: Rust with cidre bindings, a mono global tap, filters its own tap device, separate AEC crate. https://github.com/fastrepl/anarlog
- **Meetily**: ScreenCaptureKit and Core Audio back ends with a history of selection bugs; a release note lists macOS 15.6+ capture problems worked around by toggling the sample rate. https://github.com/Zackriya-Solutions/meetily/releases
- **AudioCap, Recap**: not found in today's searches. PRIOR: AudioCap (insidegui) is the reference sample for process taps with an aggregate device; Recap is a tap-based recorder. UNVERIFIED today.
- **INFERENCE**: the encrypted spool is this project's structural advantage. Every failure above loses audio silently in a streaming-only design. With a spool, plus a gap marker written when the watchdog fires, the product can show "12 s of system audio missing at 14:03" instead of a note with a hole nobody knows about.

---

## Recommended technical stack and sequencing for an on-device PL/EN product

**Stack**

| Layer | Choice | Why |
|---|---|---|
| Capture | Core Audio process tap + microphone, two channels, encrypted spool, watchdogs from 7.2 | Reliability, no Screen Recording permission, re-processing later |
| Echo | Headphone detection, reference-based suppression, text-level duplicate guard | 2.3 |
| VAD | Silero (or FSMN-VAD, which FluidAudio measures at 18% false positives on MUSAN noise against 30% for Silero) | Gate every engine |
| ASR pass 1 | Parakeet TDT v3 (CoreML), CTC vocabulary boosting with the meeting glossary | 190x real time, no silence hallucination; Polish FLEURS 8.6% in CoreML |
| ASR pass 2 | WhisperKit large-v3-turbo with `pl` pinned and glossary prompt, only on flagged segments (low confidence, wrong language, glossary near-miss) | Best published Polish read WER; language pin fixes Parakeet's drift |
| ASR to evaluate next | Nemotron-Labs-Unified-ASR-0.6B (language-ID prompt, Polish 6.01 offline / 7.09 at 1.12 s) as a possible replacement for pass 1 and for live transcript | Newest Polish-capable model; one model for live and final |
| Diarization | System channel: community-1 offline pipeline after the meeting; live labels provisional (Sortformer for ≤4 remote speakers, otherwise "Them"). Microphone channel: "me" | 2.2: streaming clustering is 38-56% DER |
| Names | Calendar attendees as candidates → meeting-app active-speaker (Accessibility) as weak supervision → LLM suggestions for confirmation → own-voice enrolment only | 2.4 |
| Correction | Glossary-constrained LLM span replacement; raw transcript kept | 1.5 |
| Notes | Topic segmentation → grammar-constrained extraction with turn ids → verification → template-driven writing steered by user notes; every bullet cites turns | 3.2 |
| LLM | 16 GB: Bielik 4.5B v3 or Qwen3-4B / Gemma 3 4B. 24-32 GB: Bielik 11B v3; Gemma 3 12B for long context. Optional external provider for the reduce step only, with consent | 3.4 |
| Archive | FTS5 BM25 + dense (BLOB + in-memory scan) + RRF; turn-window chunks; cited answers | 5 |
| Integration | Local read-only MCP server brokered by the app; Markdown/Obsidian export | 6.4 |
| Evaluation | Golden set of 20-30 meetings; MeetEval cpWER; PIER; action-item F1; citation support; LLM judge | 4 |

**Sequencing**

1. **Golden set and harness first** (4.3). Without it every later choice is taste. First measurements: Parakeet v3 against Whisper turbo against the cascade on Polish meeting audio (WER, PIER, entity recall); community-1 on the system channel (DER, cpWER).
2. **Capture hardening** against the table in 7.2, with gap markers in the spool.
3. **ASR cascade + glossary** (calendar names, user jargon, CTC boosting). Biggest quality gain per unit of work for PL/EN.
4. **Offline diarization + "me/them" + name candidates from the calendar**, user-confirmed names.
5. **Notes pipeline with citations and verification**, two or three templates, user notes as steering. This is where the product beats Granola for Polish.
6. **Consent UX** (indicator, chat notice, deletion) before any public release.
7. **Ask-the-archive**: BM25 first, dense channel second, measured on the golden questions.
8. **Meeting-app speaker names through Accessibility** (Zoom first), as weak supervision.
9. **MCP server and exports.**
10. **Live features**: live transcript, catch-me-up, pre-meeting brief.
11. **Later**: Polish conversational fine-tune of the second engine; the unified streaming model; optional voiceprints for others behind explicit opt-in.

---

## What will not work / traps

1. **Trusting FLEURS numbers.** 5-8% on read Polish becomes 20-30% on spontaneous Polish (BIGOS/PELCRA). Plan the summariser for a noisy transcript.
2. **Apple SpeechAnalyzer as the Polish engine.** Polish is not in the supported locales. Useful for English only, if at all.
3. **Voxtral, Kyutai, Moonshine, Canary-Qwen for Polish.** None lists Polish. Voxtral is reported to hear Polish as Russian.
4. **Whisper without VAD gating.** It hallucinates on silence and noise at very high rates (99.97% of non-speech clips in one study).
5. **Parakeet v3 on very short segments.** No language lock; short Polish turns drift to Czech/Russian/English. Merge segments and flag language mismatches.
6. **Free-form LLM transcript correction.** It over-corrects and invents fluent text. Constrain it to glossary spans and keep the raw text.
7. **Streaming diarization as the final answer.** 38-56% DER in FluidAudio's own AMI numbers. Re-diarize offline.
8. **Sortformer for group calls.** Four speakers maximum, mainly English training data, 35-41% DER at five or more speakers.
9. **Exclusive diarization output for scoring**, or comparing DER figures with different collars. FluidAudio's own numbers move from 10.6% to 18-24% with the protocol.
10. **DiariZen and PLLuM `nc` models in a commercial product.** Non-commercial weights.
11. **Auto-applying LLM-inferred speaker names.** 80% precision, 50% recall in the one text-only study. Suggest, never apply.
12. **Cross-meeting voiceprints of other people by default.** Art. 9 GDPR, BIPA suits against Fireflies and Otter.
13. **Stealth as a selling point.** The Granola complaint quotes "won't know it's there" and the default-off notice. Make the notice the easy path.
14. **Single-pass summarising a long transcript with a small model and no citations.** Lost-in-the-middle and unverifiable output. Extract with turn ids, verify, then write.
15. **Naive map-reduce (summaries of summaries).** Unfaithful without source context at the merge step.
16. **Letting the model resolve dates and Polish name inflection.** Do both in code against the meeting date and the attendee list.
17. **sqlite-vec loaded beside SQLCipher** as a separate SQLite, or changing the pinned unmodified GRDB build for it. At this scale a BLOB column and an in-memory scan are enough.
18. **Choosing the embedding model from English MTEB.** On PIRB, small Polish-tuned and multilingual-e5 models are well characterised; EmbeddingGemma and Qwen3-Embedding have no published Polish retrieval number.
19. **Listening only to default-device changes.** The AirPods HFP switch changes the sample rate, not the device. Listen to the rate and watch for zero buffers.
20. **Treating silence as failure, or failure as silence.** A tap gives no callbacks when nothing plays and gives zeros when permission is denied. Separate the two cases.
21. **Automatic recording start from "microphone in use".** Unreliable with Bluetooth, and a consent problem. Detect, then ask.
22. **Vendor "95% accuracy" as a target or a comparison.** No test set behind it. Compare on your own golden set.
23. **MCP that hands out transcripts without a per-client grant and a log.** It is an external-AI data flow and must sit under the same consent as the provider path.
24. **Bundling Bielik from the official repository without checking the gate.** The Hugging Face repositories require accepting terms with an account; the in-app downloader needs a permitted mirror or an agreement.
