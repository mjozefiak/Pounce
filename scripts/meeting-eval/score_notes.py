#!/usr/bin/env python3
"""Deterministic claim-level metrics for meeting notes against a gold entry (MEET-1.4, part 1).

Standard library only. Run as: python3 -I score_notes.py score|compare ...
Never prints note, transcript or name text: only meeting ids, metric names and numbers.

Gold entry: the MEET-1.3 schema (`validate_gold.py`). Notes file (`notes.json`, schema 1):
  {"schema": 1, "meeting": "<id>", "points": [
     {"kind": "summary|key_point|decision|task|question", "text": "...",
      "owner": "name or null", "due": "YYYY-MM-DD or null",     # owner/due only on tasks
      "quote": {"text": "...", "time": "mm:ss"} or null}]}

Metrics (all fractions 0..1 with their counts):
  coverage             gold key points + decisions matched by a note point (question points never match)
  quoteConfirmedShare  note points whose quote occurs, token for token, inside ONE gold transcript segment
  taskF1               gold tasks vs note tasks, maximum one-to-one matching by text, then the matched pairs are
                       checked again: level "task" (match), "owner" (+ same owner), "due" (+ same owner and due)

Matching goes through a matcher: a function (gold_text, note_text) -> similarity in 0..1. The default is
lexical (Dice over the Polish-normalized token sets, threshold MATCH_THRESHOLD). It is a proxy: where a match
needs a semantic judgement, the judge panel (part 2) passes its own matcher to the same functions.
"""

import argparse
import json
import math
import os
import sys

# `python3 -I` leaves the script's folder out of sys.path; put back only this folder, never the working directory.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import score  # noqa: E402

SCHEMA = 1
MATCH_THRESHOLD = 0.5
MIN_RUNS = 3
NON_CLAIM_KINDS = ("question",)
TASK_LEVELS = ("task", "owner", "due")


class ConsentError(Exception):
    """A meeting without cloud-judge consent was about to go to a non-local judge."""


class NotesError(Exception):
    """Malformed notes or gold input."""


# ---------------------------------------------------------------- matching


def lexical_similarity(gold_text, note_text):
    a, b = set(score.tokens(gold_text)), set(score.tokens(note_text))
    if not a or not b:
        return 0.0
    return 2 * len(a & b) / (len(a) + len(b))


def _assign(weights):
    """Maximum-weight assignment on a square matrix (Hungarian algorithm, integer weights).
    Returns col_of_row. Ties resolve by the fixed iteration order, so the result is deterministic."""
    n = len(weights)
    inf = float("inf")
    u, v, p, way = [0] * (n + 1), [0] * (n + 1), [0] * (n + 1), [0] * (n + 1)
    for i in range(1, n + 1):
        p[0] = i
        j0 = 0
        minv = [inf] * (n + 1)
        used = [False] * (n + 1)
        while True:
            used[j0] = True
            i0, delta, j1 = p[j0], inf, 0
            for j in range(1, n + 1):
                if used[j]:
                    continue
                cur = -weights[i0 - 1][j - 1] - u[i0] - v[j]
                if cur < minv[j]:
                    minv[j], way[j] = cur, j0
                if minv[j] < delta:
                    delta, j1 = minv[j], j
            for j in range(n + 1):
                if used[j]:
                    u[p[j]] += delta
                    v[j] -= delta
                else:
                    minv[j] -= delta
            j0 = j1
            if p[j0] == 0:
                break
        while j0:
            j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
    col_of_row = [None] * n
    for j in range(1, n + 1):
        if p[j]:
            col_of_row[p[j] - 1] = j - 1
    return col_of_row


_SCALE = 10 ** 6  # similarity in 0..1 scaled to integers


def match_pairs(gold_texts, note_texts, similarity=lexical_similarity, threshold=MATCH_THRESHOLD):
    """Maximum-cardinality one-to-one matching of the pairs at or above the threshold (#85).

    Among the maximum assignments the one with the highest total similarity wins; remaining ties follow
    the fixed index order. Returns [(gold_i, note_j)] sorted. Greedy best-first could leave a gold point
    unmatched although another assignment covers both."""
    ng, nn = len(gold_texts), len(note_texts)
    size = max(ng, nn)
    if not size:
        return []
    cardinality = size * _SCALE + 1  # larger than any sum of scaled similarities, so cardinality always wins
    weights = [[0] * size for _ in range(size)]
    edges = set()
    for i, g in enumerate(gold_texts):
        for j, n in enumerate(note_texts):
            s = similarity(g, n)
            if s >= threshold:
                weights[i][j] = cardinality + int(round(s * _SCALE))
                edges.add((i, j))
    cols = _assign(weights)
    return sorted((i, j) for i, j in enumerate(cols) if (i, j) in edges)


# ---------------------------------------------------------------- metrics


def _ratio(num, den):
    return {"value": (num / den) if den else 0.0, "num": num, "den": den}


def coverage(gold, notes, similarity=lexical_similarity, threshold=MATCH_THRESHOLD):
    refs = [p["text"] for p in gold.get("key_points", [])] + [p["text"] for p in gold.get("decisions", [])]
    cands = [p["text"] for p in notes["points"] if p["kind"] not in NON_CLAIM_KINDS]
    covered = len(match_pairs(refs, cands, similarity, threshold))
    return _ratio(covered, len(refs))


def quote_confirmed_share(gold, notes):
    seg_tokens = [score.tokens(s["text"]) for s in gold["transcript"]]
    points = [p for p in notes["points"] if p["kind"] not in NON_CLAIM_KINDS]
    confirmed = 0
    for p in points:
        q = p.get("quote")
        qt = score.tokens(q.get("text", "")) if isinstance(q, dict) else []
        if qt and any(score.count_subsequence(st, qt) > 0 for st in seg_tokens):
            confirmed += 1
    return _ratio(confirmed, len(points))


def _same_name(a, b):
    return score.normalize(a or "") == score.normalize(b or "")


def _f1(tp, predicted, actual):
    p = tp / predicted if predicted else 0.0
    r = tp / actual if actual else 0.0
    f = (2 * p * r / (p + r)) if (p + r) else 0.0
    return {"precision": p, "recall": r, "f1": f, "tp": tp, "predicted": predicted, "actual": actual}


def task_f1(gold, notes, similarity=lexical_similarity, threshold=MATCH_THRESHOLD):
    gt = gold.get("tasks", [])
    nt = [p for p in notes["points"] if p["kind"] == "task"]
    pairs = match_pairs([t["text"] for t in gt], [t["text"] for t in nt], similarity, threshold)
    tp = {"task": 0, "owner": 0, "due": 0}
    for i, j in pairs:
        tp["task"] += 1
        if _same_name(gt[i].get("owner"), nt[j].get("owner")):
            tp["owner"] += 1
            if (gt[i].get("due") or None) == (nt[j].get("due") or None):
                tp["due"] += 1
    return {lvl: _f1(tp[lvl], len(nt), len(gt)) for lvl in TASK_LEVELS}


def validate_notes(notes):
    if not isinstance(notes, dict) or notes.get("schema") != SCHEMA:
        raise NotesError("notes: schema must be %d" % SCHEMA)
    pts = notes.get("points")
    if not isinstance(pts, list):
        raise NotesError("points: missing")
    for i, p in enumerate(pts):
        if not isinstance(p, dict) or not isinstance(p.get("text"), str):
            raise NotesError("points[%d].text: missing" % i)
        if p.get("kind") not in ("summary", "key_point", "decision", "task", "question"):
            raise NotesError("points[%d].kind: invalid" % i)
        for key in ("owner", "due"):
            if p.get(key) is not None and not isinstance(p[key], str):
                raise NotesError("points[%d].%s: must be text or null" % (i, key))
        q = p.get("quote")
        if q is not None and not (isinstance(q, dict) and isinstance(q.get("text"), str)):
            raise NotesError("points[%d].quote: must be null or an object with text" % i)


def check_same_meeting(gold, notes):
    """Notes that name a meeting must name the gold entry's meeting."""
    mid = notes.get("meeting")
    if mid is not None and mid != gold.get("id"):
        raise NotesError("notes.meeting: does not match the gold entry id")


def score_notes(gold, notes, similarity=lexical_similarity, threshold=MATCH_THRESHOLD):
    validate_notes(notes)
    check_same_meeting(gold, notes)
    return {
        "schema": SCHEMA,
        "meeting": gold.get("id"),
        "coverage": coverage(gold, notes, similarity, threshold),
        "quoteConfirmedShare": quote_confirmed_share(gold, notes),
        "taskF1": task_f1(gold, notes, similarity, threshold),
    }


# ---------------------------------------------------------------- consent


def require_local_judge(gold, judge_is_local):
    """Refuse to send a meeting to a non-local judge unless the gold entry has cloud-judge consent."""
    if judge_is_local:
        return
    consent = gold.get("consent")
    ok = isinstance(consent, dict) and consent.get("participants_agreed") is True and consent.get("cloud_judges") is True
    if not ok:
        raise ConsentError("meeting %s has no consent for non-local judges" % gold.get("id"))


# ---------------------------------------------------------------- paired comparison


def metric_value(scored, metric):
    """metric: coverage | quoteConfirmedShare | taskF1.task | taskF1.owner | taskF1.due"""
    if metric in ("coverage", "quoteConfirmedShare"):
        return scored[metric]["value"]
    head, _, level = metric.partition(".")
    if head == "taskF1" and level in TASK_LEVELS:
        return scored["taskF1"][level]["f1"]
    raise NotesError("unknown metric: %s" % metric)


def _mean(xs):
    return sum(xs) / len(xs)


def _std(xs):
    if len(xs) < 2:
        return 0.0
    m = _mean(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def compare_variants(base_runs, cand_runs, metric):
    """Paired comparison on the same meetings.

    base_runs / cand_runs: lists of runs; a run is {meeting id: score_notes() result}.
    noise = mean over meetings of the larger run-to-run standard deviation of the two variants.
    verdict: "insufficient-runs" (< MIN_RUNS runs per variant), "above-noise" (|mean paired difference| >
    noise) or "within-noise".
    """
    if len(base_runs) < MIN_RUNS or len(cand_runs) < MIN_RUNS:
        return {"metric": metric, "verdict": "insufficient-runs", "runs": [len(base_runs), len(cand_runs)]}
    meetings = set(base_runs[0])
    for r in base_runs + cand_runs:
        meetings &= set(r)
    meetings = sorted(meetings)
    if not meetings:
        raise NotesError("no meeting is present in every run of both variants")
    diffs, noises = [], []
    for m in meetings:
        a = [metric_value(r[m], metric) for r in base_runs]
        b = [metric_value(r[m], metric) for r in cand_runs]
        diffs.append(_mean(b) - _mean(a))
        noises.append(max(_std(a), _std(b)))
    diff, noise = _mean(diffs), _mean(noises)
    return {
        "metric": metric,
        "meetings": len(meetings),
        "runs": [len(base_runs), len(cand_runs)],
        "meanDifference": diff,
        "noise": noise,
        "verdict": "above-noise" if abs(diff) > noise else "within-noise",
    }


# ---------------------------------------------------------------- output


def _pct(v):
    return "%.1f%%" % (100 * v)


def render_score(s):
    c, q = s["coverage"], s["quoteConfirmedShare"]
    out = ["meeting %s" % s["meeting"],
           "  coverage              %s (%d/%d)" % (_pct(c["value"]), c["num"], c["den"]),
           "  quote-confirmed       %s (%d/%d)" % (_pct(q["value"]), q["num"], q["den"])]
    for lvl in TASK_LEVELS:
        t = s["taskF1"][lvl]
        out.append("  task F1 (%-5s)       %s  P %s  R %s  (%d tp, %d predicted, %d gold)" % (
            lvl, _pct(t["f1"]), _pct(t["precision"]), _pct(t["recall"]), t["tp"], t["predicted"], t["actual"]))
    return "\n".join(out) + "\n"


def render_compare(c):
    if c["verdict"] == "insufficient-runs":
        return "%s: insufficient runs (%d vs %d, need %d per variant)\n" % (c["metric"], c["runs"][0], c["runs"][1], MIN_RUNS)
    return "%s: difference %+.4f, noise %.4f over %d meetings, runs %d vs %d: %s\n" % (
        c["metric"], c["meanDifference"], c["noise"], c["meetings"], c["runs"][0], c["runs"][1], c["verdict"])


def _load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="score_notes.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("score")
    s.add_argument("--gold", required=True, help="entry.json of the gold set")
    s.add_argument("--notes", required=True)
    s.add_argument("--out")
    c = sub.add_parser("compare")
    c.add_argument("--baseline", required=True, help="JSON list of runs, each {meeting id: score result}")
    c.add_argument("--candidate", required=True)
    c.add_argument("--metric", default="coverage")
    args = ap.parse_args(argv)
    try:
        if args.cmd == "score":
            scored = score_notes(_load(args.gold), _load(args.notes))
            sys.stdout.write(render_score(scored))
            if args.out:
                with open(args.out, "w", encoding="utf-8") as f:
                    json.dump(scored, f, ensure_ascii=False, indent=2)
            return 0
        sys.stdout.write(render_compare(compare_variants(_load(args.baseline), _load(args.candidate), args.metric)))
        return 0
    except (NotesError, OSError, ValueError, KeyError) as e:
        sys.stderr.write("score_notes.py: %s\n" % type(e).__name__)
        return 2


if __name__ == "__main__":
    sys.exit(main())
