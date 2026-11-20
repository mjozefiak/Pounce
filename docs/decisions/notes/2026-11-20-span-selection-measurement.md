# Measurement note: removing dictated self-corrections by span selection

Date: 2026-11-20. Status: measurement only. No product behaviour changes in this PR; the prototype is test code
(`Tests/DictationPluginTests/SpanSelect/`) and the real-model harness is off by default.

## The idea

Today the built-in model rewrites the chunk and `FormatterGuard` tries to work out from the result what the model
did (PR 134, five review rounds, every new rule opens a new variant). Span selection turns it round:

1. Code finds a spoken retraction marker from the list in `FormatterGuard.retractionMarkers`
   ("nie, czekaj", "no wait", "I mean", "sorry", "actually", ...), the longest one at the earliest word.
2. The model gets the words **before** the marker, numbered, and answers ONE thing: the number of the first word
   the marker takes back, or `none`. The answer is limited by a GBNF grammar (`llama_sampler_init_grammar`) to
   `none` or a number in the window of the `N` words before the marker. An answer outside the grammar would be
   parsed and rejected as `none` (never happened: 0 invalid answers in 268 calls per model).
3. Code builds the result: **input minus `[start ... end of marker]`**. The model never writes text.
4. Optional negation rule: if the removed span holds a negation and none stays after the marker, the decision
   becomes `none`.
5. The rest of the pipeline is `main`'s: cleanup prompt v1, `FormatterGuard` of `main`.

Grammar support: the pinned llama.cpp release b11600 exposes `llama_sampler_init_grammar` in its C header
(checked in the XCFramework header and in the llama.cpp documentation). `LlamaRuntime` does not use it today and
is not changed here; the harness links `llama` directly for the test target only (one line in `Package.swift`).

## What was measured

Inputs: the invented autocorrect corpus (79 cases: 38 withdrawals, 21 negatives, 20 false starts and fillers) and
the invented guard probe tables of PR 134 (265 distinct inputs; 118 have a correct cleanup in the tables and are
scored, 147 have only wrong outputs listed and are scored only on negation and on known-bad outputs). Only invented
text is used. Greedy decoding, one run per model (deterministic). Prompt: 6 invented few-shot turns, written once
before the first run and not changed afterwards (the examples are checked not to overlap the corpus). Machine:
Apple M4 Max, 128 GB, other sessions may have been running; latency is a guide, not a benchmark.

Models:

| Model | License | File | Size | Note |
|---|---|---|---|---|
| Qwen3 4B Instruct 2507, Q4_K_M | Apache-2.0 | catalog default | 2.5 GB | |
| Qwen3 30B-A3B Instruct 2507, Q4_K_M | Apache-2.0 | catalog | 18.6 GB | |
| Qwen3.5 122B-A10B, Q3_K_M | Apache-2.0 | local evaluation copy | 56.4 GB | hybrid/recurrent: no prompt-prefix cache |
| Gemma 4 E4B it, Q4_K_M (new) | Apache-2.0 | `unsloth/gemma-4-E4B-it-GGUF` @ `bfc15c382204943c3a8fff0c750b94ae2364d7a3` | 4 977 171 584 B | SHA-256 `85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87`, verified after download, kept in the evaluation folder only, not in the app |

Gemma 4 loads in b11600, but `llama_chat_apply_template` (the only template API in the C library, and the one
`LlamaRuntime` uses) does not know its template. The harness writes the turn format by hand. A product use would
need that solved first.

## Results (N = 8, corpus of 79)

"Cut only" is the deterministic result of the cut, without the cleanup step. "Pipeline" is cut + cleanup v1 +
`main`'s guard. "main v1" and "#134" are the same corpus through `main`'s pipeline and PR 134's prompt v2 with its
guard, with the same harness (the old figures 46/47 for #134 were reproduced; `main` v1 measured now is 44/79 on
4B, not the older 52).

| Model | Cut only, rule on: all / withdrawals / negatives | Pipeline, rule on: all / withdrawals / negatives | main v1: all / wd / neg | #134 (prompt v2): all / wd / neg |
|---|---|---|---|---|
| 4B | 61 / 33 of 38 / 19 of 21 | **67** / 32 / 18 | 44 / 8 / 19 | 46 / 10 / 19 |
| 30B-A3B | 60 / 34 / 17 | **67** / 35 / 16 | 39 / 5 / 18 | 47 / 10 / 21 |
| Gemma 4 E4B | 60 / 34 / 17 | **70** / 35 / 17 | 45 / 6 / 21 | not run |
| 122B-A10B | 63 / 33 / 21 | **72** / 34 / 20 | 48 / 10 / 20 | not run |

Cut only, rule off: 4B 62 (34 / 19), 30B 61 (35 / 17), Gemma 61 (35 / 17), 122B 64 (34 / 21). The 20 false-start and
filler cases are not touched by the cut (9 of 20 pass without the cleanup step, in every model).

Only chunks with a detected marker reach the model: 37 of 38 withdrawals, but only **5 of the 21 negatives** (the
others use words that are not in the marker list, so they are safe by construction), and 0 of the false starts and
fillers. A chunk without a marker costs nothing.

### Choice of the start (single-marker chunks with a correct cut, rule off)

"Exact" is the gold start; "off by one" is one word too late (short, leaves a repeated word) or too early (long,
removes a word of the kept version); "missed" is `none` where a cut was right; "false alarm" is a cut where `none`
was right.

| Model | Corpus withdrawals (n = 37): exact / off by one / wrong / missed | Corpus negatives called (n = 5): false alarms | Probes (n = 68): exact / off by one / wrong / missed / false alarm |
|---|---|---|---|
| 4B | 24 / 8 (7 short, 1 long) / 3 / 2 | 2 | 27 / 17 / 8 / 8 / 7 |
| 30B-A3B | 24 / 10 (7 short, 3 long) / 1 / 2 | 4 | 34 / 11 / 11 / 4 / 5 |
| Gemma 4 E4B | 19 / 15 (12 short, 3 long) / 3 / 0 | 4 | 31 / 15 / 11 / 3 / 7 |
| 122B-A10B | 22 / 12 (10 short, 2 long) / 0 / 3 | 0 | 34 / 13 / 7 / 6 / 1 |

The window size barely matters on the corpus: every one of the 37 correct cuts starts within 4 words of the marker.
`N = 4` gives the same corpus numbers as `N = 12`; for 4B on the probes it has fewer wrong choices (6 against 8) and more missed ones (10 against 8).

The usual mistake is a start one word late: the model picks the noun instead of the word of the phrase that is
said again ("kup chleb w [piątek] nie, czekaj, w sobotę" cut from the noun leaves "kup chleb w w sobotę"). The cleanup step
removes most of those repeats, which is why the pipeline column is much better than the cut-only column on the
fillers and false starts.

### Harm in the final texts (labeled: 79 corpus + 118 probes = 197; N = 8, rule on)

| Model | Texts that lost a word the correct cleanup has | Negation lost | Cuts where `none` was right | Result equals a reviewer's known-bad output (rule off / on) |
|---|---|---|---|---|
| 4B | 24 | 1 | 9 (probes) | 7 / 6 |
| 30B-A3B | 25 | 2 | 6 | 9 / 6 |
| Gemma 4 E4B | 31 | 2 | 9 | 11 / 9 |
| 122B-A10B | 9 | 0 | 2 | 7 / 5 |

On the 147 unlabeled probes the model-free count of results that lose a negation outside the marker is 7 to 11
per model with the rule off and **0 with the rule on**; the rule costs 2 to 5 correct cuts per model on the scored
sets (for example a retraction whose withdrawn part contains "nie" as part of the sentence, "z Anną nie
przepraszam z Hanną"). The negation lost in the corpus negatives is the marker itself ("nie, czekaj" read as a
retraction in "napisz Piotrkowi nie czekaj na mnie"); the rule cannot see it, because the negation is part of the
marker.

### Latency and memory (per model call; one call per detected marker)

| Model | Warm prefix p50 / p95 | No prefix cache p50 / p95 | Prompt tokens | Peak resident, whole test process |
|---|---|---|---|---|
| 4B | 0.064 s / 0.080 s | 0.333 s / 0.336 s | 457 | 3.2 GB |
| 30B-A3B | 0.097 s / 0.116 s | 0.311 s / 0.317 s | 457 | 18.0 GB |
| Gemma 4 E4B | 0.088 s / 0.107 s | 0.368 s / 0.401 s | 447 | 5.2 GB |
| 122B-A10B | no cache possible: 0.896 s / 0.943 s | 0.897 s / 0.929 s | 446 | 50.8 GB |

The prompt is static except for the last turn, so the examples can stay in the KV cache; the answer is 1 to 3
tokens. Cleanup afterwards: 0.11 to 0.19 s p50 on the small models (1.3 s on 122B). For 4B the cut adds well
under a second to a chunk that has a marker and nothing to a chunk that has none. Time to load: 0.3 s (4B, warm
file cache), 3.9 s (Gemma), 16 s (30B), 19 s (122B).

## Model-free upper bound of harm (the property tests)

Asserted for every possible decision (`none` and every start before the marker) of every corpus and probe input,
with chains of several markers (20 probe chunks have two or more): the result is the input's words in the input's
order; it never holds a word that is not in the input; the words after the marker are untouched; the removed span
is one contiguous run that ends at the marker; a start at or before the first withdrawn word never leaves the
withdrawn version next to the final one. A wrong start can therefore only over-remove words that stand directly
before the marker, or under-remove.

Worst case if the model chose adversarially (labeled callable inputs, decisions counted over the whole space):

| Set | N | Decisions | Over-removing | Inputs where some decision over-removes | Negation lost (decisions; inputs) no rule -> rule |
|---|---|---|---|---|---|
| Corpus withdrawals (37) | 4 | 179 | 44 (rule: 43) | 30 | 0 |
| | 8 | 203 | 68 (67) | 34 | 0 |
| Corpus negatives called (5) | any | 14 | 9 | 5 | 4; 2 inputs, unchanged by the rule |
| Probes with a correct cleanup (78) | 4 | 423 | 155 (151) | 54 | 2; 2 -> 0 |
| | 8 | 504 | 220 (210) | 58 | 5; 2 -> 0 |
| Unlabeled probes (123 callable) | 4 / 6 / 8 | | | | inputs where a start could drop a negation: 24 / 29 / 30; with the rule: 0 / 0 / 1 |

So a smaller `N` shrinks the damage but does not remove it; the rule removes the cases where a negation vanishes
without another one staying, which is the meaning-reversing class. What is left is a damaged cut next to the
marker: at most `N` words plus the marker.

## Recommendation

**Replace the rewriting of retractions by span selection**, keeping cleanup v1 for fillers, false starts and
punctuation and `main`'s guard as it is, under these conditions:

- **Model:** the default 4B. It reaches 67 of 79 end to end (against 44 on `main` and 46 on #134), 24 exact starts
  of 37, a median of 64 ms per call with the prefix cache, and 3 GB. The 30B is no better at choosing (4 false
  alarms of 5 on marker-as-content negatives), Gemma 4 chooses worse (19 exact) and cannot be templated by
  `LlamaRuntime`, the 122B is the only one with no false alarm on the corpus negatives but needs 51 GB and 0.9 s
  per call.
- **N = 6** (every correct cut starts within 4 words; 6 leaves room; 8 and 12 only add wrong choices).
- **Negation rule on.** It costs one correct cut on the corpus and removes every negation-dropping result on the
  unlabeled probes.
- **Do not ship without a visible, reversible cut** (see the variants below). The residual errors are real and
  silent otherwise: on 4B, 2 of the 5 negatives that contain a marker ("czerwone światło to znaczy stop a nie
  zwolnij", "napisz Piotrkowi nie czekaj na mnie z kolacją") lose 4 words each, 8 of 37 starts are off by one, and
  chains such as "w piątek czekaj w poniedziałek sorry we wtorek" are cut wrongly by every model.

What this does not show: the corpus is small (37 cuts, 5 called negatives), the probe set is partly unlabeled, the
prompt was written once and not tuned, and it is one run per model. The next steps that should come before a
product change are a larger synthetic set of markers used as content and of chains, a deterministic generator for
the "word of the repeated phrase" candidates to cut the off-by-one mistakes, and the missing markers ("albo
jednak", plain "no") in the list.

## UX variants (not implemented; the owner decides after a mock-up)

| Variant | What the user sees | Consequence |
|---|---|---|
| A. No signal | Nothing | Simplest and fastest. A wrong cut (about 1 start in 4 is off by one on 4B, 2 of 5 content markers) is silent data loss in the pasted text. Not recommended. |
| B. HUD line after the paste, one key to undo | The removed fragment struck through for a few seconds; one key puts the raw text back in place (extends `dictation.pasteLastRaw`) | Costs nothing when the cut is right, fixes a wrong one in one key. Works only right after the paste; the raw text and the removed span are kept in memory only. Recommended. |
| C. Show only risky cuts | Same as B, but only when the cut is long, the marker is ambiguous ("actually", "właściwie", "to znaczy") or the model's margin is low | Less noise; needs the model's probability margin (not measured here) and hides the silent errors it misjudges. |
| D. Preview before the paste | The cut is shown before it is pasted | Safe, but adds a step to every chunk that has a marker. |
| E. History only | The removed fragment is visible in the dictation history, like Wispr's "undo AI edit" | No live signal; the user finds out later. A useful addition to B, not a replacement. |

## How to reproduce

- Model-free tests (run in CI): `swift test --filter SpanSelectPropertyTests` (prints the worst-case tables).
- Real model, off by default:
  `LINTEL_SPAN_MODEL=<gguf> LINTEL_SPAN_LABEL=<name> LINTEL_SPAN_NS=4,8,12 LINTEL_SPAN_E2E=1 swift test --filter RealSpanSelectTests`
  (`LINTEL_SPAN_TEMPLATE=gemma4` for Gemma 4; `LINTEL_SPAN_OUT=<dir>` writes the decisions as JSON). Run it alone
  and once per model; it loads its own copy of the model.
- #134 numbers: `LINTEL_LLAMA_MODEL=<gguf> swift test --filter AutocorrectCorpusTests/realModelPassCountsPerCategory`.
