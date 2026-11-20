# Measurement note: removing dictated self-corrections by span selection

Date: 2026-11-20. Status: measurement only. No product behaviour changes in this PR; the prototype is test code
(`Tests/DictationPluginTests/SpanSelect/`) and the real-model harness is off by default.

An independent review re-ran every measurement (section "Review and re-measurement" at the end). It corrects four
statements of the first version: the explanation of `main`'s 52/79 (it was measured with a relaxed guard of PR 134,
not with `main`'s guard), the latency (the warm prefix cache does not exist in the product), the claim about words
after the marker in chains (it holds after the last marker only), and the order of the rules. The recommendation at
the end of the review supersedes the one below.

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
text is used. Greedy decoding, one run per model (the review confirmed it is deterministic: three runs and a run without the prefix
cache give the same answers). Prompt: 6 invented few-shot turns, written once
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
4B, not the older 52: the 52 was prompt v1 run with the relaxed guard PR 134 had at the time, see the review).

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
tokens. **Not in the product today:** `LlamaRuntime` clears the KV memory before every request, and in the product
order (span call, then the cleanup of the same chunk) one KV sequence holds the other prompt when the next span call
comes; the review measured that order at the cold figure (4B 0.33 s). Use the "no prefix cache" column. Cleanup afterwards: 0.11 to 0.19 s p50 on the small models (1.3 s on 122B). For 4B the cut adds about a third
of a second to a chunk that has a marker (no cache) and nothing to a chunk that has none. Time to load: 0.3 s (4B, warm
file cache), 3.9 s (Gemma), 16 s (30B), 19 s (122B).

## Model-free upper bound of harm (the property tests)

Asserted for every possible decision (`none` and every start before the marker) of every corpus and probe input,
with chains of several markers (20 probe chunks have two or more): the result is the input's words in the input's
order; it never holds a word that is not in the input; the words after the marker are untouched (in a chain: the
words after the LAST marker; a later cut may remove an earlier marker and the words after it, by design); the removed span
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

## Review and re-measurement (2026-11-20)

An independent reviewer re-ran the harness on the same invented corpus and probes, without changing the prompt.
Same machine class (Apple silicon, 128 GB), other sessions running, so latency is a guide.

### 1. Repeatability: the result is deterministic

Three runs per model with the prefix cache (4B, 30B-A3B, Gemma 4 E4B; 122B-A10B one run, as allowed), plus one 4B run
with **no** prefix cache (every prompt decoded from scratch, as `LlamaRuntime` does). Every model answer (289 to 293
calls per `N`, for `N` = 8 and 6) and every final text was identical across the runs of a model, and the 4B run
without the cache gave the same answers as the runs with it. Greedy decoding plus the grammar on one machine is
deterministic here, so there is no spread to report: the "mean" is the single value, the spread is 0. The numbers of
the first version were reproduced exactly (pipeline 67 / 67 / 70 / 72; start choice 24-8-3-2, 24-10-1-2, 19-15-3-0,
22-12-0-3). What the runs do not show is the spread over prompt wording, model files or another machine.

| Model (N = 8, negation rule on) | Pipeline: all / withdrawals / negatives | Strict score (all) | main v1 (same harness, same scorer) | main v1 strict | main v1 if its guard accepted every answer |
|---|---|---|---|---|---|
| Qwen3 4B | 67 / 32 / 18 | 58 | 44 / 8 / 19 | 39 | 53 |
| Qwen3 30B-A3B | 67 / 35 / 16 | 63 | 39 / 5 / 18 | 38 | 48 |
| Gemma 4 E4B | 70 / 35 / 17 | 67 | 45 / 6 / 21 | 44 | 56 |
| Qwen3.5 122B-A10B | 72 / 34 / 20 | 64 | 48 / 10 / 20 | 46 | 74 |

Start choice (single-marker corpus withdrawals, n = 37, no rule): exact / off by one / wrong / missed = 4B 24 / 8 / 3 /
2, 30B 24 / 10 / 1 / 2, Gemma 19 / 15 / 3 / 0, 122B 22 / 12 / 0 / 3. False alarms on the 5 negatives that reach the
model: 2, 4, 4, 0. Invalid answers: 0 in every run.

### 2. `main` v1: 44/79 confirmed, and why the old figure was 52

The 44 is right for `main` as it is: prompt v1 (byte-for-byte the prompt of `main`), `main`'s guard
(`MainGuardReference`, the same checks as `main`'s `FormatterGuard`), the same inputs and the same scorer as the span
track. The 52 of the description of PR 134 was measured in commit `912a0ae8` with "the version 1 prompt run with the
final guard" of that time, a PR 134 guard that relaxed the 0.6 lower length bound for chunks with a marker. With
`main`'s guard, 9 of 79 answers of 4B are rejected as too short and the raw text (both versions) is pasted; **all 9
would pass**: 44 + 9 = 53, the earlier 52/53 within one case (that run used `LlamaRuntime`, this one the harness
wrapper; both are greedy and give the same answers here). Not a harness error and not a prompt change: a different
guard.

Fairness of the comparison. Both tracks use the same inputs, the same cleanup prompt, the same guard code and the
same scorer (`AutocorrectCorpus.satisfies`). Two things favour the span track and are now stated:
- The scorer checks a SET of words (`must_keep` present, `must_drop` absent). It does not see a doubled word ("w w
  sobotę") nor a lost word of the kept version that is not in `must_keep`, which is exactly the span track's error
  mode. The review added a strict score (no word of the reference that the input had is missing, no doubled word the
  reference does not have), applied to both tracks: the gap stays (4B 58 against 39).
- The guard's length floor is computed against the cut text, so a correct removal is not thrown back to the raw
  text, while `main`'s guard throws away 9 correct shortenings of 4B (11 of Gemma, 26 of 122B). Much of the gap is
  this floor: with every answer accepted, `main` v1 would reach 53 / 48 / 56 / 74, so on 122B rewriting without the
  floor would beat the span track (74 against 72). Accepting every rewrite is not an option (that is the class of
  PR 134's five review rounds), so the span track's real gain on 4B is 67 against 44 safely, or 67 against 53 at
  best.

### 3. Silent errors: the off-by-one start and a deterministic alignment rule

The model's off-by-one starts on the corpus (all four models, no rule): 36 starts one word late ("short") and 9
one word early ("long"). Short: the word left behind is a preposition repeated right after the marker in 18 cases, an
article in 4, a conjunction in 1, a content word repeated after the marker in 8, a content word not repeated in 5.
Long: the removed word of the kept version is a preposition in 7, a content word in 2.

`SpanSelect.Rules.align` (harness option): move the start one word back or forward onto the word that the repair
after the marker opens with (keys folded for "we/w", "ze/z" and the like, "an/a"). Model-free over every start of
every labeled single-marker input (`N` = 8): corpus 45 off-by-one starts become exact, 0 exact starts are spoiled;
probes 60 become exact, 1 exact start becomes off by one, 1 off-by-one start becomes wrong. On the models' own
choices: off by one goes from 8 to 3 (4B), 10 to 4 (30B), 15 to 4 (Gemma), 12 to 2 (122B), and no exact start is
lost. End to end it changes almost nothing (4B 67, Gemma 70 -> 71) because the cleanup step already removes the
doubled word; it matters when the cleanup is rejected and the cut text is pasted (cut-only strict score: 4B 50 -> 54,
30B 48 -> 52, Gemma 45 -> 54, 122B 47 -> 56). Every text the alignment changed was checked: it removes a doubled word
(17 to 26 per model), keeps one more word of the final version ("dziś", "dzwoń"), or removes a folded "we" before
"w"; none lost content. The higher count of "result equals a known-bad output" with the alignment is an artefact of
exact string comparison: the unaligned results were the same wrong cut plus a doubled word, which did not match the
listed text.

**A defect found and fixed in the harness: the order of the rules.** The first version applied only the negation
rule. With the alignment before it, a start the model put on a negation ("do [not] send it yet sorry send it now")
moved one word forward, the span no longer held "not", the rule did not fire and the result was "do not send it now"
(the sentence turned round, 4B). The rules now judge the model's own choice first: a choice the negation rule
refuses stays refused, then the alignment, then the rule again on the final span.

How many words can be lost: at most `N` words plus the marker in one decision (the longest removal seen: 9 words at
`N` = 8, 7 at `N` = 6). Largest number of reference words lost in one final text: 4B 8 at `N` = 8 and 5 at `N` = 6
(probes); in the corpus end to end 2 (122B) to 5 (4B).

### 4. False alarms on markers used as content, and the negation inside a marker

Only 5 corpus negatives reach the model. Two of them hold a negating marker used as content ("... nie czekaj na
mnie ...", "nie, czekaj" read as a retraction): the negation rule cannot see them, because the negation is the
marker's own word. Callable inputs whose marker holds a negation: 13 corpus retractions, 2 corrections, 2 negatives,
57 probes. Proposal measured: `anchorNegatingMarkers`, a marker that holds a negation cuts only when the first word
after it appears in the removed span. Model-free it refuses 11 of the 34 correct cuts that have a negating marker and
makes both negating negatives impossible to cut. On the models (N = 8, with align and tail): 4B 67/32/18 -> 66/30/19
end to end, the negation loss on the labeled texts (cut only) goes 1 -> 0; 30B 67 -> 66 (negatives 16 -> 17); Gemma 71 -> 70 (17 -> 19);
122B 72 -> 70. The same anchor for every marker (`anchorAll`, the voxtype rule) is too expensive: it refuses 41 of
101 correct cuts and the pipeline drops to 57 / 57 / 63 / 65.

### 5. Chains of markers

No corpus case has two markers; 20 probes do (6 labeled). Left to right, `none` leaves a marker as content and the
next marker's window may then cover it; a cut continues from the cut's start. A marker at the very end of a chunk
("we need sixty units actually") was cut by 4B ("we need"): a deterministic rule `requireRepair` (no word after the
marker, no cut) fixes it at no cost on the corpus and is now part of the recommended set. No two markers stand side
by side in the data ("marker in a marker" is handled by the longest match: "nie, to znaczy" before "to znaczy").
A cut can never create a new marker by joining two words (asserted). The variant "one decision per marker, from the
end" (`runFromEnd`) gives the same corpus results (no chains there) and mixed results on the 6 labeled chains: 4B
4 -> 5 (rule on), but 3 -> 3 with align and tail; 30B 3 -> 3; Gemma 3 -> 4; 122B 4 -> 4; with it 4B and 30B lose a
negation on one unlabeled chain. Six chains decide nothing; keep left to right and build a synthetic chain set
before choosing.

### 6. What the property tests prove

`everyDecisionKeepsTheInputWordsInOrderAndEverythingAfterTheMarker` tries EVERY start before the first marker plus
`none` (not only the window) of every corpus and probe input and asserts: subsequence, no foreign word, the words
after the marker unchanged, one contiguous span that ends at the marker. The chain test now asserts the same for
every leaf of the whole decision tree inside the window (the walk is asserted not to hit its cap; an empty
expectation was removed) and that the words after the last marker stay. The new
`theDeterministicRulesOnlyKeepCancelOrShiftByOne` asserts for every start of the window, `N` = 4/6/8/12, eight rule
sets, both chain orders, that a rule only keeps, refuses or moves the start by one inside the window, never turns
`none` into a cut, and that the result stays a subsequence that keeps the words after the last marker.
"Never both versions with a covering start" is asserted on the 37 corpus withdrawals only (the probes have no
annotation of the withdrawn words). The negation statements are partly counted, not asserted: the rule's own
behaviour is asserted for every start of the first marker; "0 negation lost with the rule" on the unlabeled probes is
a printed count, and it is about negations outside the marker, so the negation that IS the marker ("nie, czekaj"
as content) is a known gap (2 corpus cases, see section 4).

### 7. Latency

Measured now: first call right after the load (cold start of a first dictation) 4B 0.34 s, 30B 0.39 s, Gemma 1.16 s,
122B 0.98 s; load 0.3 to 1.1 s (4B, file in the page cache), 13 s (30B), 4.8 s (Gemma), 46 s (122B). Per call with
the warm prefix 4B 0.06 to 0.08 s p50, but in the product order (span call, then the cleanup prompt) the prefix is
gone: 4B 0.33 s, 30B 0.32 s, Gemma 0.36 s, 122B 0.94 s p50, the same as without a cache. Without the cache the 4B
cleanup step is 0.43 s p50 (0.13 s with a warm prefix). So on 4B a chunk with a marker costs about 0.34 s more than
today; a chunk without a marker costs nothing. A prefix cache in the product needs `LlamaRuntime` to keep two KV
states (`llama_state_seq_*` or two sequences), which it does not do, and `LLMLease` hands the same model to Meetings
and Notes, whose prompts would evict it as well.

### 8. Recommendation of the review (supersedes the one above)

**Go on with span selection, with Qwen3 4B, `N` = 6, and these deterministic rules: negation (on the model's choice
and on the final span), alignment, require a repair after the marker, and the anchor for negating markers.** On 4B
this gives 66 of 79 end to end (30 / 38 withdrawals, 19 / 21 negatives; strict 57) against 44 for `main`, no lost
negation on the labeled sets, at most 7 words removed in one decision, about 0.34 s per marker. Ship it only with
the visible, reversible cut (variant B above): 1 of 5 called negatives still cuts wrongly and 9 probes with no
retraction are cut. `N` = 6 and `N` = 8 give the same corpus results; 6 halves the worst loss on the probes (5 words
against 8). 30B is not better than 4B on the decision (4 of 5 false alarms); Gemma 4 chooses better after the
alignment but needs its own chat template; 122B is too large. Keep `main`'s guard for the cleanup step, computed
against the cut text.

What a production spec must contain:
1. Where the cut runs: after the transcript and before `Segmenter` (a retraction must not straddle two chunks), and
   what happens when a marker lies within `N` words of a chunk boundary.
2. The marker list (shared with `FormatterGuard.retractionMarkers`), the missing ones ("albo jednak", plain "no"),
   and the rule that the earliest, longest marker wins.
3. The decision: prompt (versioned, examples checked against the corpus), GBNF grammar, greedy decoding, the window
   `N` = 6, an invalid answer means `none`.
4. `LLMRuntime` changes (additive): a grammar parameter, and optionally the probabilities of the answer tokens for a
   confidence margin; the lease key equal to the cleanup's (same model, same context length) so the cut does not
   swap models; what happens when the lease is busy (no cut).
5. The deterministic rules in this order: negation on the model's choice, alignment, require a repair, anchor for
   negating markers, negation on the final span; each one can only refuse or move by one word (property tests as
   here).
6. Chains: left to right, one decision per marker, a removed span may cover an earlier marker; a synthetic chain set
   before release.
7. The cleanup step and its guard run on the cut text; when the guard rejects, the CUT text is pasted, not the raw.
8. UX: the HUD line with the removed fragment and one key to undo (in place, from memory only), the raw transcript
   kept in memory as today (`pasteLastRaw`), nothing written to logs.
9. Latency budget measured in the product path (no prefix cache unless `LlamaRuntime` gets one) and the cold start.
10. A larger synthetic test set: markers used as content (especially negating ones), chains, a marker at a chunk end,
    corrections without a marker (out of scope, stated), and a gate: no lost negation and no false alarm on the
    negatives that reach the model, before the default is switched on.

## How to reproduce

- Model-free tests (run in CI): `swift test --filter SpanSelectPropertyTests` (prints the worst-case tables).
- Real model, off by default:
  `LINTEL_SPAN_MODEL=<gguf> LINTEL_SPAN_LABEL=<name> LINTEL_SPAN_NS=8,6 LINTEL_SPAN_E2E=1 swift test --filter RealSpanSelectTests`
  (`LINTEL_SPAN_TEMPLATE=gemma4` for Gemma 4; `LINTEL_SPAN_NOCACHE=1` decodes every prompt from scratch;
  `LINTEL_SPAN_OUT=<dir>` writes the answers, the decisions of every rule set, the final texts and the cleanups as
  JSON). Run it alone and once per model; it loads its own copy of the model. It prints every rule set of
  `RealSpanSelectTests.variants` (cut only, strict score, start choice, chains, alignment changes, end to end).
- Replay without a model: `LINTEL_SPAN_REPLAY=<json>[,<json>...] swift test --filter SpanSelectReplayTests` runs
  every rule set on the stored answers and cleanups (a query or cleanup that was not stored is counted).
- #134 numbers: `LINTEL_LLAMA_MODEL=<gguf> swift test --filter AutocorrectCorpusTests/realModelPassCountsPerCategory`.
