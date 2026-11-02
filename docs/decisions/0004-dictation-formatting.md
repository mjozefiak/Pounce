# ADR 0004: Formatting model and chunk size for dictation

- Status: accepted (replaces spike 0.2 of the dictation spec)
- Date: 2026-11-02
- Spec: `.ai/specs/2026-11-01-voice-dictation.md`, Phase 0

## Context

Pounce does not ship or download the formatting LLM: it calls the user's loopback OpenAI-compatible
server (Ollama, LM Studio, llama-server). Settings only recommend a model. Spike 0.2 was going to pick
the recommendation and the chunk limit `N` on the user's recordings; the user chose public benchmarks
instead. Target machine: Mac Studio, 128 GB, so 30B-class models fit; per-chunk latency decides.

## Evidence (collected 2026-11-02)

**Output tokens are the bottleneck.** Polish costs 2.69 tokens/word with the Qwen3 tokenizer and
3.22 with Bielik's Mistral tokenizer, versus 1.17 for English [1]. Prefill is cheap (~1,700 tok/s for
a 30B-A3B MoE on an M4 Max [2]); decode speed sets the time per chunk.

| Model | Polish evidence | Decode on M-series | License |
|---|---|---|---|
| **Qwen3.6-35B-A3B** (MoE), 4-bit | no Polish benchmark; Qwen3.5-35B-A3B: INCLUDE 79.7, MMMLU 85.2, IFEval 91.9 [3] | 78–91 tok/s on M3 Ultra (community) [4] | Apache-2.0 |
| Qwen3-30B-A3B-Instruct-2507, 4-bit | Qwen3-32B: Open PL 64.24, PLCC 37.67 [1] | 113 tok/s on M4 Max [2] | Apache-2.0 |
| **Bielik-11B-v3.0-Instruct**, Q6/Q8 | best Polish: Open PL 65.93, PLCC 71.83 (Gemma-3-27B 47.33, Qwen3-32B 37.67) [1] | ~55–65 tok/s (estimated, not measured) [5] | Apache-2.0 |
| Gemma 4 26B-A4B (MoE), 4-bit | MMMLU 86.3, no Polish score [6] | 62–85 tok/s on M3 Ultra [4] | Apache-2.0 |
| Qwen3.6-27B (dense), 4-bit | Qwen3.5-27B IFEval 95.0 | 22–39 tok/s [4] — too slow for live chunks | Apache-2.0 |
| **Qwen3-4B-Instruct-2507**, 4-bit | Qwen3-4B: Open PL 55.49 [1] | 134 tok/s on M4 Max [2] | Apache-2.0 |

70B-class models do not pay off: Llama-3.3-70B scores 66.40 on Open PL, about the same as Bielik 11B [1].

Other apps: superwhisper's local cleanup model is a Qwen3-0.6B fine-tune, English-only, run with
greedy decoding [7]; its users report the LLM answering dictated questions [8]. VoiceInk wraps the
transcript in tags under a fixed "transcription editor" system prompt [9].

## Decision

1. **Recommended model in Settings: Qwen3.6-35B-A3B, 4-bit (MLX or Ollama), thinking off.** It is the
   fastest strong multilingual model that fits comfortably in 128 GB and handles mixed PL/EN.
2. **Polish-first alternative: Bielik-11B-v3.0-Instruct (Q6/Q8)**, shown as „najlepszy polski”.
   It has the best Polish evidence, but it is slower per word (bigger tokenizer cost) and has no
   published English instruction-following score.
3. **Light option for smaller Macs: Qwen3-4B-Instruct-2507.**
4. **Chunk limit `N` = 60 words** (soft threshold ~40 words + pause ≥ 1.5 s, hard cut at the end of
   a sentence before 60). Arithmetic: 60 Polish words ≈ 160 tokens with Qwen; at 78–91 tok/s that
   is ~1.8–2.1 s plus ~0.2 s prefill. With Bielik: ≈ 195 tokens, ~3–3.5 s (estimated).
5. **Tail budget: < 3 s** after recording stops, for a tail ≤ 60 words, with the recommended model on
   an M-series Max/Ultra. On a base M-series chip with a 4B model the old < 8 s budget still applies.
6. **Request settings:** `temperature: 0`, `chat_template_kwargs: {"enable_thinking": false}` (Qwen3.5/3.6
   no longer honour the `/no_think` soft switch [3]; servers that ignore the field are covered by
   `<think>` stripping), `max_tokens` = words × 4 + 64. The timeout stays `5 s + words × 0.1 s × 2`
   (17 s for 60 words).
7. **Prompt guard techniques** (from [7][8][9], not benchmarked): the system prompt says the input
   is a transcript to clean, never a request to answer, and the output keeps the input's language;
   the transcript sits in delimiters in the user turn; few-shot pairs where the input is a question
   or a command (PL and EN) and the output is that question cleaned up. `FormatterGuard` stays the
   safety net (length ratio, language, answer-like openings such as „Oto”, "Sure").

## Consequences

- No new dependency: Pounce still talks to one OpenAI-compatible endpoint.
- Whether Ollama's OpenAI endpoint honours `chat_template_kwargs` is checked in step 2.1; if not,
  `<think>` stripping and the guard handle it.
- The prompt regression set (step 2.5) is written as text fixtures (PL, EN, mixed, with dictated
  questions and commands) instead of being transcribed from the user's recordings.

## Sources

- [1] https://arxiv.org/pdf/2601.11579 (Bielik 11B v3 report; Tables 2, 5, 7, 9)
- [2] https://gist.github.com/awni/c1790e4c3a39be6e8f1c4afd42423d2d
- [3] https://huggingface.co/Qwen/Qwen3.5-35B-A3B, https://huggingface.co/Qwen/Qwen3.6-35B-A3B
- [4] https://omlx.ai/benchmarks (community measurements)
- [5] scaled from https://github.com/ggml-org/llama.cpp/discussions/4167
- [6] https://huggingface.co/google/gemma-4-26B-A4B-it
- [7] https://huggingface.co/superwhisper/s1-mini-GGUF
- [8] https://superwhisper.userjot.com/board/p/ability-to-have-language-model-ignore-questions.
- [9] https://tryvoiceink.com/docs/prompt-management
