#!/usr/bin/env python3
"""Score meeting-transcription ASR results against reference transcripts.

Standard library only. Run as: python3 -I score.py score|compare ...
Never prints segment or reference text; only numbers, recording names and term names.

Reference file (one per recording, kept outside the repository), optional keys beyond `excerpts`,
`terms` and `silences`:
  englishTerms  list of English terms; "English term error" = share of those present in the
                reference excerpts that the hypothesis lacks.
  speakerTurns  [{startMs, endMs, speaker, text?}]; speaker "unknown" is excluded and counted.
                `text` on every turn enables cpWER (needs `pip install meeteval`; skipped otherwise).
  speakerCount  number of people, when it differs from the distinct names in speakerTurns.
Hypothesis segments may carry `speaker` and `words` [{startMs, endMs, speaker}].
Warnings follow spec 2026-11-06-meeting-speaker-quality, step 1.3: more than 10% mixed segments
or a cluster count that differs from the people by 2 or more.
"""

import argparse
import json
import os
import sys
import unicodedata

SCHEMA = 1

PERCENT_KEYS = ("wer", "cer", "termRecall", "termError", "wrongSpeakerWordShare", "mixedSegmentShare", "cpWer")

# Warning thresholds fixed in spec 2026-11-06-meeting-speaker-quality, step 1.3.
MIXED_SEGMENT_WARN = 0.10
CLUSTER_DIFF_WARN = 2
# A reference speaker counts as present in a segment when they cover at least this much of it.
MIX_MIN_MS = 500
MIX_MIN_SHARE = 0.15

# metric key -> (label, direction) ; direction: "lower", "higher" or None (informational)
METRICS = [
    ("wer", "WER", "lower"),
    ("cer", "CER", "lower"),
    ("termRecall", "Term recall", "higher"),
    ("termError", "English term error", "lower"),
    ("wrongSpeakerWordShare", "Wrong-speaker words", "lower"),
    ("mixedSegmentShare", "Mixed segments", "lower"),
    ("clusterDiff", "Cluster diff", None),
    ("cpWer", "cpWER", "lower"),
    ("silenceWords", "Silence words", "lower"),
    ("loops", "Loops", "lower"),
    ("rtf", "RTF", "lower"),
    ("peakMB", "Peak MB", "lower"),
    ("deferredSegments", "Deferred", "lower"),
    ("diarSpeakers", "Diar speakers", None),
    ("diarSeconds", "Diar seconds", None),
]


# ---------------------------------------------------------------- normalisation


def normalize(text):
    """NFC, lowercase, punctuation (incl. apostrophes/hyphens) -> separators."""
    text = unicodedata.normalize("NFC", text or "").lower()
    out = []
    for ch in text:
        if ch.isalnum() or unicodedata.category(ch).startswith("M"):
            out.append(ch)
        else:
            out.append(" ")
    return " ".join("".join(out).split())


_UNITS = {
    "zero": 0, "jeden": 1, "jedna": 1, "jedno": 1, "jednego": 1, "dwa": 2, "dwie": 2, "dwóch": 2,
    "dwoje": 2, "trzy": 3, "trzech": 3, "cztery": 4, "czterech": 4, "pięć": 5, "pięciu": 5,
    "sześć": 6, "sześciu": 6, "siedem": 7, "siedmiu": 7, "osiem": 8, "ośmiu": 8, "dziewięć": 9,
    "dziewięciu": 9, "dziesięć": 10, "dziesięciu": 10, "jedenaście": 11, "dwanaście": 12,
    "trzynaście": 13, "czternaście": 14, "piętnaście": 15, "szesnaście": 16, "siedemnaście": 17,
    "osiemnaście": 18, "dziewiętnaście": 19,
}
_TENS = {
    "dwadzieścia": 20, "trzydzieści": 30, "czterdzieści": 40, "pięćdziesiąt": 50,
    "sześćdziesiąt": 60, "siedemdziesiąt": 70, "osiemdziesiąt": 80, "dziewięćdziesiąt": 90,
}
_HUNDREDS = {
    "sto": 100, "dwieście": 200, "trzysta": 300, "czterysta": 400, "pięćset": 500,
    "sześćset": 600, "siedemset": 700, "osiemset": 800, "dziewięćset": 900,
}
_THOUSANDS = {"tysiąc", "tysiące", "tysięcy"}


def _number_rank(tok):
    """(value, rank) for a Polish cardinal word, else None. Ranks: units/teens 1, tens 2, hundreds 3."""
    if tok in _UNITS:
        return (_UNITS[tok], 1)
    if tok in _TENS:
        return (_TENS[tok], 2)
    if tok in _HUNDREDS:
        return (_HUNDREDS[tok], 3)
    return None


def fold_numbers(toks):
    """Replace runs of Polish cardinal words by digits (`dwadzieścia pięć` -> `25`).

    Words in a run must descend (hundreds, tens, units); `tysiąc` multiplies what precedes it,
    a digit token included (`5 tysięcy` -> `5000`, like `pięć tysięcy`). A word that cannot
    continue the run starts a new number. Other digit tokens are left as they are.
    """
    out = []
    i, n = 0, len(toks)
    while i < n:
        digit_multiplier = toks[i].isdigit() and i + 1 < n and toks[i + 1] in _THOUSANDS
        if not digit_multiplier and _number_rank(toks[i]) is None and toks[i] not in _THOUSANDS:
            out.append(toks[i])
            i += 1
            continue
        total, current, last_rank = 0, 0, 4
        used_current = thousand_seen = False
        if digit_multiplier:
            current, used_current = int(toks[i]), True
            i += 1
        while i < n:
            t = toks[i]
            if t in _THOUSANDS:
                if thousand_seen:  # a second "tysiąc" in a row starts a new number
                    break
                total += (current if used_current else 1) * 1000
                current, used_current, last_rank, thousand_seen = 0, False, 4, True
                i += 1
                continue
            nr = _number_rank(t)
            if nr is None or nr[1] >= last_rank:
                break
            current += nr[0]
            used_current = True
            last_rank = nr[1]
            i += 1
        out.append(str(total + current))
    return out


def tokens(text):
    """The one Polish normalizer: `normalize`, then spelled-out numbers folded to digits."""
    n = normalize(text)
    return fold_numbers(n.split()) if n else []


# ---------------------------------------------------------------- edit distance


def edit_counts(ref, hyp):
    """Levenshtein over sequences. Returns (subs, dels, ins)."""
    # strip common prefix/suffix (does not change the optimal distance)
    a, b = list(ref), list(hyp)
    p = 0
    while p < len(a) and p < len(b) and a[p] == b[p]:
        p += 1
    a, b = a[p:], b[p:]
    s = 0
    while s < len(a) and s < len(b) and a[-1 - s] == b[-1 - s]:
        s += 1
    if s:
        a, b = a[:-s], b[:-s]
    if not a:
        return (0, 0, len(b))
    if not b:
        return (0, len(a), 0)
    # row cells: (dist, subs, dels, ins)
    prev = [(j, 0, 0, j) for j in range(len(b) + 1)]
    for i in range(1, len(a) + 1):
        cur = [(i, 0, i, 0)]
        ai = a[i - 1]
        for j in range(1, len(b) + 1):
            d, su, de, ins = prev[j - 1]
            if ai == b[j - 1]:
                best = (d, su, de, ins)
            else:
                best = (d + 1, su + 1, de, ins)
            d2, su2, de2, in2 = prev[j]
            if d2 + 1 < best[0]:
                best = (d2 + 1, su2, de2 + 1, in2)
            d3, su3, de3, in3 = cur[j - 1]
            if d3 + 1 < best[0]:
                best = (d3 + 1, su3, de3, in3 + 1)
            cur.append(best)
        prev = cur
    _, su, de, ins = prev[-1]
    return (su, de, ins)


def _rate(ref_seq, hyp_seq):
    if len(ref_seq) == 0:
        return None
    su, de, ins = edit_counts(ref_seq, hyp_seq)
    return {
        "rate": (su + de + ins) / len(ref_seq),
        "substitutions": su,
        "deletions": de,
        "insertions": ins,
        "refLength": len(ref_seq),
        "errors": su + de + ins,
    }


def wer(ref_tokens, hyp_tokens):
    """Word error rate dict, or None for an empty reference."""
    return _rate(list(ref_tokens), list(hyp_tokens))


def _chars(tok):
    return list(" ".join(tok))


def cer(ref_tokens, hyp_tokens):
    """Character error rate dict (spaces between words included), or None."""
    return _rate(_chars(ref_tokens), _chars(hyp_tokens))


# ---------------------------------------------------------------- selection


def _midpoint(seg):
    return (seg["startMs"] + seg["endMs"]) / 2


def excerpt_hypothesis(segments, start_ms, end_ms):
    """Texts of segments whose midpoint is in [start_ms, end_ms), by startMs."""
    chosen = [s for s in segments if start_ms <= _midpoint(s) < end_ms]
    chosen.sort(key=lambda s: s["startMs"])
    return " ".join(s.get("text", "") for s in chosen)


def count_subsequence(seq, sub):
    if not sub or len(sub) > len(seq):
        return 0
    n = len(sub)
    return sum(1 for i in range(len(seq) - n + 1) if seq[i : i + n] == sub)


def term_counts(terms, ref_token_lists, hyp_token_lists):
    """Per term: {"ref", "hyp", "recall"}; terms with 0 in reference skipped."""
    result = {}
    for term in terms:
        t = tokens(term)
        if not t:
            continue
        r = sum(count_subsequence(x, t) for x in ref_token_lists)
        if r == 0:
            continue
        h = sum(count_subsequence(x, t) for x in hyp_token_lists)
        result[term] = {"ref": r, "hyp": h, "recall": min(h, r) / r}
    return result


def silence_report(segments, silences):
    spans = []
    total = 0
    for sp in silences:
        words = 0
        for s in segments:
            if sp["startMs"] <= _midpoint(s) < sp["endMs"]:
                words += len(tokens(s.get("text", "")))
        spans.append({"startMs": sp["startMs"], "endMs": sp["endMs"], "words": words})
        total += words
    return {"totalWords": total, "spans": spans}


def count_loops(toks):
    """Token repeated >=5x in a row, or 2-8 token phrase repeated >=3x in a row."""
    n = len(toks)
    i = 0
    loops = 0
    while i < n:
        j = i
        while j < n and toks[j] == toks[i]:
            j += 1
        if j - i >= 5:
            loops += 1
            i = j
            continue
        found = False
        for size in range(2, 9):
            if i + size * 3 > n:
                break
            phrase = toks[i : i + size]
            k = 1
            while toks[i + k * size : i + (k + 1) * size] == phrase:
                k += 1
            if k >= 3:
                loops += 1
                i += size * k
                found = True
                break
        if not found:
            i += 1
    return loops


def count_loops_in_segments(segments):
    return sum(count_loops(tokens(s.get("text", ""))) for s in segments)


# ---------------------------------------------------------------- speakers


def _is_known(name):
    return isinstance(name, str) and name.strip() != "" and name.strip().lower() != "unknown"


def valid_turns(turns):
    """Reference speaker turns with numeric bounds, sorted by start."""
    out = []
    for t in turns or []:
        if not isinstance(t, dict):
            continue
        a, b = t.get("startMs"), t.get("endMs")
        if isinstance(a, (int, float)) and isinstance(b, (int, float)) and b > a:
            out.append(t)
    return sorted(out, key=lambda t: (t["startMs"], t["endMs"]))


def ref_speaker_at(turns, ms):
    """(covered, speaker): covered False when no turn holds `ms`; speaker None for `unknown`."""
    for t in turns:
        if t["startMs"] <= ms < t["endMs"]:
            return (True, t["speaker"] if _is_known(t.get("speaker")) else None)
    return (False, None)


def hypothesis_words(segments):
    """[(centreMs, cluster)] for the diarized segments.

    Uses the per-word times and speakers of a segment when it carries `words`; otherwise the
    segment's words are spread evenly over its duration under the segment's speaker.
    """
    out = []
    for sg in segments:
        label = sg.get("speaker")
        words = sg.get("words")
        if isinstance(words, list) and words:
            for w in words:
                if not isinstance(w, dict):
                    continue
                a, b = w.get("startMs"), w.get("endMs")
                if not isinstance(a, (int, float)) or not isinstance(b, (int, float)):
                    continue
                who = w.get("speaker") if _is_known(w.get("speaker")) else label
                if _is_known(who):
                    out.append(((a + b) / 2, who))
            continue
        if not _is_known(label):
            continue
        n = len(tokens(sg.get("text", "")))
        dur = sg["endMs"] - sg["startMs"]
        for i in range(n):
            out.append((sg["startMs"] + (i + 0.5) * dur / n, label))
    return out


def map_clusters(pairs):
    """One-to-one cluster -> reference speaker map, greedy by co-occurring words."""
    counts = {}
    for cluster, ref in pairs:
        counts[(cluster, ref)] = counts.get((cluster, ref), 0) + 1
    mapping, used = {}, set()
    for (cluster, ref), _ in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        if cluster in mapping or ref in used:
            continue
        mapping[cluster] = ref
        used.add(ref)
    return mapping


def segment_is_mixed(segment, turns):
    """(mixed, known): mixed when two known reference speakers each cover a real part of it."""
    dur = segment["endMs"] - segment["startMs"]
    if dur <= 0:
        return (False, False)
    cover = {}
    for t in turns:
        if not _is_known(t.get("speaker")):
            continue
        ov = min(segment["endMs"], t["endMs"]) - max(segment["startMs"], t["startMs"])
        if ov > 0:
            cover[t["speaker"]] = cover.get(t["speaker"], 0) + ov
    if not cover:
        return (False, False)
    need = max(MIX_MIN_MS, MIX_MIN_SHARE * dur)
    return (sum(1 for v in cover.values() if v >= need) >= 2, True)


def speaker_report(segments, turns, speaker_count=None):
    """Speaker metrics of the hypothesis against reference turns; None without turns."""
    turns = valid_turns(turns)
    if not turns:
        return None
    pairs = []
    unknown_words = 0
    hyp_words = hypothesis_words(segments)
    for ms, cluster in hyp_words:
        covered, ref = ref_speaker_at(turns, ms)
        if not covered:
            continue
        if ref is None:
            unknown_words += 1
            continue
        pairs.append((cluster, ref))
    mapping = map_clusters(pairs)
    wrong = sum(1 for c, r in pairs if mapping.get(c) != r)

    mixed = evaluated = unknown_segments = 0
    for sg in segments:
        is_mixed, known = segment_is_mixed(sg, turns)
        if known:
            evaluated += 1
            mixed += 1 if is_mixed else 0
        elif sg["endMs"] > sg["startMs"]:
            unknown_segments += 1

    # Segment labels and per-word labels: a cluster that only shows up in `words` still counts.
    hyp_clusters = len({sg["speaker"] for sg in segments if _is_known(sg.get("speaker"))}
                       | {cluster for _, cluster in hyp_words})
    ref_people = (speaker_count if isinstance(speaker_count, int) and speaker_count > 0
                  else len({t["speaker"] for t in turns if _is_known(t.get("speaker"))}))
    diff = hyp_clusters - ref_people
    rep = {
        "wrongSpeakerWordShare": wrong / len(pairs) if pairs else None,
        "wrongSpeakerWords": wrong,
        "countedWords": len(pairs),
        "unknownWords": unknown_words,
        "mixedSegmentShare": mixed / evaluated if evaluated else None,
        "mixedSegments": mixed,
        "evaluatedSegments": evaluated,
        "unknownSegments": unknown_segments,
        "hypClusters": hyp_clusters,
        "refSpeakers": ref_people,
        "clusterDiff": diff,
        "warnings": [],
    }
    if rep["mixedSegmentShare"] is not None and rep["mixedSegmentShare"] > MIXED_SEGMENT_WARN:
        rep["warnings"].append(
            f"mixed segments {rep['mixedSegmentShare'] * 100:.1f}% exceed {MIXED_SEGMENT_WARN * 100:.0f}%")
    if abs(diff) >= CLUSTER_DIFF_WARN:
        rep["warnings"].append(f"cluster count differs by {abs(diff)} (limit {CLUSTER_DIFF_WARN - 1})")
    return rep


def _import_meeteval():
    try:
        import meeteval  # type: ignore
    except ImportError:
        return None
    return meeteval


def cp_wer(segments, turns):
    """(value, note): cpWER through MeetEval when installed and the turns carry `text`.

    value is None with a note saying why the row is skipped; the other metrics are unaffected.
    """
    turns = valid_turns(turns)
    if not turns or not all(isinstance(t.get("text"), str) for t in turns):
        return (None, "cpWER skipped: reference turns carry no text")
    mv = _import_meeteval()
    if mv is None:
        return (None, "cpWER skipped: MeetEval is not installed (pip install meeteval)")
    start, end = turns[0]["startMs"], max(t["endMs"] for t in turns)
    ref = [{"session_id": "s", "speaker": t["speaker"], "words": " ".join(tokens(t["text"])),
            "start_time": t["startMs"] / 1000, "end_time": t["endMs"] / 1000}
           for t in turns if _is_known(t.get("speaker"))]
    hyp = [{"session_id": "s", "speaker": sg["speaker"], "words": " ".join(tokens(sg.get("text", ""))),
            "start_time": sg["startMs"] / 1000, "end_time": sg["endMs"] / 1000}
           for sg in segments
           if _is_known(sg.get("speaker")) and start <= _midpoint(sg) < end]
    try:
        result = mv.wer.api.cpwer(reference=ref, hypothesis=hyp)
        rates = [r.error_rate for r in result.values()]
    except Exception as e:  # MeetEval's API moves between releases; never fail the run
        return (None, f"cpWER skipped: MeetEval call failed ({type(e).__name__})")
    rates = [r for r in rates if r is not None]
    return ((sum(rates) / len(rates)) if rates else None, None)


# ---------------------------------------------------------------- scoring


def _num(d, key):
    v = d.get(key) if isinstance(d, dict) else None
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def score_recording(result, refs):
    """result: parsed result JSON; refs: parsed reference JSON or None."""
    asr = result.get("asr") or {}
    segments = asr.get("segments") or []
    diar = result.get("diarization")
    out = {
        "recording": result.get("recording"),
        "config": result.get("config"),
        "audioSeconds": result.get("audioSeconds"),
        "hasRefs": refs is not None,
        "wer": None,
        "cer": None,
        "werDetail": None,
        "cerDetail": None,
        "drift": [],
        "termRecall": None,
        "terms": {},
        "termError": None,
        "speakers": None,
        "wrongSpeakerWordShare": None,
        "mixedSegmentShare": None,
        "clusterDiff": None,
        "cpWer": None,
        "notices": [],
        "silenceWords": None,
        "silenceSpans": [],
        "loops": count_loops_in_segments(segments),
        "rtf": _num(asr, "rtf"),
        "peakMB": _num(asr, "peakFootprintMB"),
        "deferredSegments": _num(asr, "deferredSegments"),
        "diarSpeakers": _num(diar, "speakers"),
        "diarSeconds": _num(diar, "seconds"),
    }
    notes = result.get("notes")
    if isinstance(notes, dict):
        out["notes"] = {
            k: notes.get(k)
            for k in ("model", "seconds", "peakFootprintMB", "status", "chunkCount",
                      "verifiedPoints", "dropped", "failedChunks", "reduceFailed")
        }
    if refs is None:
        return out

    ref_lists, hyp_lists = [], []
    tot = {"s": 0, "d": 0, "i": 0, "n": 0}
    ctot = {"s": 0, "d": 0, "i": 0, "n": 0}
    for ex in refs.get("excerpts") or []:
        rt = tokens(ex.get("text", ""))
        ht = tokens(excerpt_hypothesis(segments, ex["startMs"], ex["endMs"]))
        ref_lists.append(rt)
        hyp_lists.append(ht)
        w = wer(rt, ht)
        out["drift"].append(
            {"startMs": ex["startMs"], "endMs": ex["endMs"],
             "wer": None if w is None else w["rate"]}
        )
        if w is not None:
            tot["s"] += w["substitutions"]
            tot["d"] += w["deletions"]
            tot["i"] += w["insertions"]
            tot["n"] += w["refLength"]
            c = cer(rt, ht)
            ctot["s"] += c["substitutions"]
            ctot["d"] += c["deletions"]
            ctot["i"] += c["insertions"]
            ctot["n"] += c["refLength"]
    for agg, key, det in ((tot, "wer", "werDetail"), (ctot, "cer", "cerDetail")):
        if agg["n"] > 0:
            out[key] = (agg["s"] + agg["d"] + agg["i"]) / agg["n"]
            out[det] = {"substitutions": agg["s"], "deletions": agg["d"],
                        "insertions": agg["i"], "refLength": agg["n"]}

    terms = term_counts(refs.get("terms") or [], ref_lists, hyp_lists)
    out["terms"] = terms
    total_ref = sum(t["ref"] for t in terms.values())
    if total_ref:
        out["termRecall"] = sum(min(t["hyp"], t["ref"]) for t in terms.values()) / total_ref

    eng = term_counts(refs.get("englishTerms") or [], ref_lists, hyp_lists)
    if eng:
        out["termError"] = sum(1 for t in eng.values() if t["hyp"] == 0) / len(eng)

    sp = speaker_report(segments, refs.get("speakerTurns"), refs.get("speakerCount"))
    if sp is not None:
        out["speakers"] = sp
        for key in ("wrongSpeakerWordShare", "mixedSegmentShare", "clusterDiff"):
            out[key] = sp[key]
        out["notices"].extend(sp["warnings"])
        out["cpWer"], note = cp_wer(segments, refs.get("speakerTurns"))
        if note:
            out["notices"].append(note)

    sil = silence_report(segments, refs.get("silences") or [])
    out["silenceWords"] = sil["totalWords"]
    out["silenceSpans"] = sil["spans"]
    return out


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def score_run(results_dir, refs_dir):
    recs = {}
    problems = []
    for fn in sorted(os.listdir(results_dir)):
        if not fn.endswith(".json"):
            continue
        name = fn[:-5]
        try:
            result = load_json(os.path.join(results_dir, fn))
        except (OSError, ValueError) as e:
            problems.append(f"{name}: unreadable result ({type(e).__name__})")
            continue
        refs = None
        rp = os.path.join(refs_dir, fn)
        if os.path.isfile(rp):
            try:
                refs = load_json(rp)
            except (OSError, ValueError) as e:
                problems.append(f"{name}: unreadable refs ({type(e).__name__})")
        try:
            recs[name] = score_recording(result, refs)
        except (KeyError, TypeError, AttributeError) as e:
            problems.append(f"{name}: malformed input ({type(e).__name__})")
    return {"schema": SCHEMA, "resultsDir": results_dir, "recordings": recs,
            "problems": problems}


# ---------------------------------------------------------------- formatting


def _fmt(v, key=None):
    if v is None:
        return "n/a"
    if isinstance(v, float):
        if key in PERCENT_KEYS:
            return f"{v * 100:.2f}%"
        return f"{v:.3f}".rstrip("0").rstrip(".") if v != int(v) else str(int(v))
    return str(v)


def render_score(scored):
    lines = ["# ASR score", ""]
    cols = [m for m in METRICS]
    lines.append("| Recording | " + " | ".join(c[1] for c in cols) + " |")
    lines.append("|---|" + "---|" * len(cols))
    for name, r in scored["recordings"].items():
        cells = [_fmt(r.get(k), k) for k, _, _ in cols]
        lines.append(f"| {name} | " + " | ".join(cells) + " |")
    lines.append("")
    for name, r in scored["recordings"].items():
        if not r["hasRefs"]:
            lines.append(f"- {name}: no reference file, WER/CER/terms/silence skipped")
            continue
        if r["werDetail"]:
            d = r["werDetail"]
            lines.append(
                f"- {name}: WER subs={d['substitutions']} del={d['deletions']} "
                f"ins={d['insertions']} of {d['refLength']} ref words")
        drift = ", ".join(_fmt(x["wer"], "wer") for x in r["drift"])
        if drift:
            lines.append(f"- {name}: drift (WER per excerpt): {drift}")
        sp = r.get("speakers")
        if sp:
            lines.append(
                f"- {name}: speakers wrong words {sp['wrongSpeakerWords']}/{sp['countedWords']} "
                f"(+{sp['unknownWords']} unknown), mixed segments {sp['mixedSegments']}/"
                f"{sp['evaluatedSegments']} (+{sp['unknownSegments']} unknown), clusters "
                f"{sp['hypClusters']} vs {sp['refSpeakers']} people")
        for note in r.get("notices", []):
            lines.append(f"- {name}: {note}")
        for term, t in r["terms"].items():
            lines.append(f"- {name}: term `{term}` recall {t['recall'] * 100:.0f}% "
                         f"({min(t['hyp'], t['ref'])}/{t['ref']})")
    for p in scored.get("problems", []):
        lines.append(f"- problem: {p}")
    return "\n".join(lines) + "\n"


def compare_runs(base, cand):
    brec, crec = base["recordings"], cand["recordings"]
    rows = []
    for name in sorted(set(brec) & set(crec)):
        for key, label, direction in METRICS:
            b, c = brec[name].get(key), crec[name].get(key)
            if b is None or c is None:
                rows.append({"recording": name, "metric": key, "label": label,
                             "baseline": b, "candidate": c, "delta": None,
                             "pct": None, "verdict": "n/a"})
                continue
            delta = c - b
            pct = None if b == 0 else delta / abs(b) * 100
            if abs(delta) < 1e-12 or direction is None:
                verdict = "same" if abs(delta) < 1e-12 else "info"
            elif (delta < 0) == (direction == "lower"):
                verdict = "improved"
            else:
                verdict = "regressed"
            rows.append({"recording": name, "metric": key, "label": label,
                         "baseline": b, "candidate": c, "delta": delta,
                         "pct": pct, "verdict": verdict})
    return {
        "rows": rows,
        "onlyInBaseline": sorted(set(brec) - set(crec)),
        "onlyInCandidate": sorted(set(crec) - set(brec)),
    }


def render_compare(cmp):
    lines = ["# ASR comparison", "",
             "| Recording | Metric | Baseline | Candidate | Delta | Delta % | Verdict |",
             "|---|---|---|---|---|---|---|"]
    for r in cmp["rows"]:
        k = r["metric"]
        delta = "n/a" if r["delta"] is None else (
            f"{r['delta'] * 100:+.2f} pp" if k in PERCENT_KEYS
            else f"{r['delta']:+.4g}")
        pct = "n/a" if r["pct"] is None else f"{r['pct']:+.1f}%"
        lines.append(f"| {r['recording']} | {r['label']} | {_fmt(r['baseline'], k)} | "
                     f"{_fmt(r['candidate'], k)} | {delta} | {pct} | {r['verdict']} |")
    lines.append("")
    for n in cmp["onlyInBaseline"]:
        lines.append(f"- {n}: only in baseline (missing in candidate)")
    for n in cmp["onlyInCandidate"]:
        lines.append(f"- {n}: only in candidate (missing in baseline)")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- CLI


def main(argv=None):
    ap = argparse.ArgumentParser(prog="score.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("score")
    s.add_argument("--results", required=True)
    s.add_argument("--refs", required=True)
    s.add_argument("--out")
    c = sub.add_parser("compare")
    c.add_argument("--baseline", required=True)
    c.add_argument("--candidate", required=True)
    args = ap.parse_args(argv)

    if args.cmd == "score":
        scored = score_run(args.results, args.refs)
        sys.stdout.write(render_score(scored))
        if args.out:
            with open(args.out, "w", encoding="utf-8") as f:
                json.dump(scored, f, ensure_ascii=False, indent=2)
        return 0
    cmp = compare_runs(load_json(args.baseline), load_json(args.candidate))
    sys.stdout.write(render_compare(cmp))
    return 0


if __name__ == "__main__":
    sys.exit(main())
