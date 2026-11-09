#!/usr/bin/env python3
"""Score meeting-transcription ASR results against reference transcripts.

Standard library only. Run as: python3 -I score.py score|compare ...
Never prints segment or reference text; only numbers, recording names and term names.
"""

import argparse
import json
import os
import sys
import unicodedata

SCHEMA = 1

# metric key -> (label, direction) ; direction: "lower", "higher" or None (informational)
METRICS = [
    ("wer", "WER", "lower"),
    ("cer", "CER", "lower"),
    ("termRecall", "Term recall", "higher"),
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


def tokens(text):
    n = normalize(text)
    return n.split() if n else []


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
        if key in ("wer", "cer", "termRecall"):
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
            f"{r['delta'] * 100:+.2f} pp" if k in ("wer", "cer", "termRecall")
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
