#!/usr/bin/env python3
"""Validate and reduce answers of the Fable judge (fable-judge.md, judge_protocol_version 1).

Standard library only. Run as:
  python3 -I validate_judge_result.py validate [--segments N] [--meeting ID] RESULT.json ...
  python3 -I validate_judge_result.py public [--label L] RESULT.json
  python3 -I validate_judge_result.py aggregate [--label L] [--markdown] RESULT.json RESULT.json RESULT.json ...
  python3 -I validate_judge_result.py check-trap --expected trap-expected.json RESULT.json

This tool never calls a judge and never sends anything anywhere. A judge answer holds meeting text (quotes and
reasons) and stays outside the repository; `public` and `aggregate` reduce it to numbers and category names,
which is the only part that may go into the repository or a pull request. Nothing here prints note, transcript
or name text: only field paths, labels, category names and numbers.
Exit codes: 0 valid (or trap caught), 1 invalid (or trap missed), 2 usage/input error.
"""

import argparse
import json
import os
import re
import statistics
import sys

PROTOCOL = 1
PUBLIC_SCHEMA = 1
ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
REF_RE = re.compile(r"^r[0-9]+$")
# a label is chosen by the operator (M01, "M01 before"), never taken from the answer
LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._+-]{0,39}$")
REFERENCE_KINDS = ("decision", "task", "finding", "number_or_date", "context")
COVERAGES = ("missed", "partial")
FABRICATION_CATEGORIES = ("fact", "person_or_attribution", "number_or_date", "decision", "task")
SEVERITIES = ("major", "minor")
FORMAT_DEFECTS = ("timestamp_in_notes", "author_marker", "raw_speech", "duplicate", "wrong_section",
                  "verbosity", "missing_summary", "language", "markup")
HARD_FORMAT_DEFECTS = ("timestamp_in_notes", "author_marker")  # owner decisions 3 and 4 of 2026-11-19
DIMENSIONS = ("coverage", "faithfulness", "tasks", "formatting")
WEIGHTS = {"coverage": 8, "faithfulness": 9, "tasks": 3, "formatting": 5}  # 4 points each: 100 in total
MIN_RUNS = 3
# Thresholds: a first proposal without data, to be calibrated after the first series (fable-judge.md section 5).
PASS_OVERALL, FAIL_OVERALL = 80, 60
UNSTABLE_DIMENSION_SPREAD, UNSTABLE_OVERALL_SPREAD = 1, 10
TOP_KEYS = ("protocol_version", "meeting", "reference", "omissions", "fabrications", "format_defects",
            "evidence", "scores", "overall")


class InputError(Exception):
    """A file could not be read or the arguments make no sense. Never carries meeting text."""


def _is_text(v):
    return isinstance(v, str) and v.strip() != ""


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


# ---------------------------------------------------------------- validation


def validate_result(result, segment_count=None, meeting=None):
    """Return a list of error strings ('<field path>: <reason>'). Empty = valid.

    segment_count: number of lines of segments.jsonl; when given, every `segment` must be below it.
    meeting: id from meta.json; when given, the answer must name the same meeting.
    """
    errors = []

    def err(path, why):
        errors.append(f"{path}: {why}")

    def obj(value, path, keys):
        """True when value is an object with exactly `keys`; reports missing and unknown keys by name."""
        if not isinstance(value, dict):
            err(path, "must be an object")
            return False
        prefix = f"{path}." if path else ""
        for k in keys:
            if k not in value:
                err(f"{prefix}{k}", "missing")
        unknown = len(set(value) - set(keys))
        if unknown:  # the judge chose these names, so they are counted, never printed
            err(path or "result", f"{unknown} unknown key(s)")
        return True

    def items(key):
        value = result.get(key)
        if key in result and not isinstance(value, list):
            err(key, "must be a list")
        return value if isinstance(value, list) else []

    def segment(value, path, nullable):
        if value is None and nullable:
            return
        if not _is_int(value) or value < 0:
            err(path, "must be a segment index" + (" or null" if nullable else ""))
        elif segment_count is not None and value >= segment_count:
            err(path, "is beyond the last segment")

    if not obj(result, "", TOP_KEYS):
        return ["result: must be a JSON object"]

    if "protocol_version" in result and not (_is_int(result["protocol_version"]) and result["protocol_version"] == PROTOCOL):
        err("protocol_version", f"must be {PROTOCOL}")
    if "meeting" in result:
        if not (isinstance(result["meeting"], str) and ID_RE.match(result["meeting"])):
            err("meeting", "must match [a-z0-9][a-z0-9_-]* (max 64)")
        elif meeting is not None and result["meeting"] != meeting:
            err("meeting", "is not the meeting that was judged")

    kinds = {}
    reference = items("reference")
    if "reference" in result and isinstance(result["reference"], list) and not reference:
        err("reference", "needs at least 1 item")
    for i, r in enumerate(reference):
        p = f"reference[{i}]"
        if not obj(r, p, ("id", "kind", "text", "owner", "due", "segment", "core")):
            continue
        rid = r.get("id")
        if "id" in r:
            if not (isinstance(rid, str) and REF_RE.match(rid)):
                err(f"{p}.id", "must match r<number>")
            elif rid in kinds:
                err(f"{p}.id", "duplicate id")
            else:
                kinds[rid] = r.get("kind")
        if "kind" in r and r["kind"] not in REFERENCE_KINDS:
            err(f"{p}.kind", "must be one of " + "|".join(REFERENCE_KINDS))
        if "text" in r and not _is_text(r["text"]):
            err(f"{p}.text", "must be non-empty text")
        for k in ("owner", "due"):
            if k in r and r[k] is not None:
                if not _is_text(r[k]):
                    err(f"{p}.{k}", "must be text or null")
                elif r.get("kind") != "task":
                    err(f"{p}.{k}", "must be null unless kind is task")
        if "segment" in r:
            segment(r["segment"], f"{p}.segment", nullable=False)
        if "core" in r and not isinstance(r["core"], bool):
            err(f"{p}.core", "must be true or false")

    seen = set()
    for i, o in enumerate(items("omissions")):
        p = f"omissions[{i}]"
        if not obj(o, p, ("ref_id", "coverage", "why")):
            continue
        if "ref_id" in o:
            if not isinstance(o["ref_id"], str) or o["ref_id"] not in kinds:
                err(f"{p}.ref_id", "is not an id of the reference list")
            elif o["ref_id"] in seen:
                err(f"{p}.ref_id", "listed twice")
            else:
                seen.add(o["ref_id"])
        if "coverage" in o and o["coverage"] not in COVERAGES:
            err(f"{p}.coverage", "must be one of " + "|".join(COVERAGES))
        if "why" in o and not _is_text(o["why"]):
            err(f"{p}.why", "must be non-empty text")

    for i, f in enumerate(items("fabrications")):
        p = f"fabrications[{i}]"
        if not obj(f, p, ("category", "severity", "notes_quote", "why", "segment")):
            continue
        if "category" in f and f["category"] not in FABRICATION_CATEGORIES:
            err(f"{p}.category", "must be one of " + "|".join(FABRICATION_CATEGORIES))
        if "severity" in f and f["severity"] not in SEVERITIES:
            err(f"{p}.severity", "must be one of " + "|".join(SEVERITIES))
        for k in ("notes_quote", "why"):
            if k in f and not _is_text(f[k]):
                err(f"{p}.{k}", "must be non-empty text")
        if "segment" in f:
            segment(f["segment"], f"{p}.segment", nullable=True)

    seen = set()
    for i, d in enumerate(items("format_defects")):
        p = f"format_defects[{i}]"
        if not obj(d, p, ("category", "count", "why")):
            continue
        if "category" in d:
            if d["category"] not in FORMAT_DEFECTS:
                err(f"{p}.category", "must be one of " + "|".join(FORMAT_DEFECTS))
            elif d["category"] in seen:
                err(f"{p}.category", "listed twice (use count)")
            else:
                seen.add(d["category"])
        if "count" in d and not (_is_int(d["count"]) and d["count"] >= 1):
            err(f"{p}.count", "must be a whole number, at least 1")
        if "why" in d and not _is_text(d["why"]):
            err(f"{p}.why", "must be non-empty text")

    if "evidence" in result and obj(result["evidence"], "evidence", DIMENSIONS):
        for k in DIMENSIONS:
            if k in result["evidence"] and not _is_text(result["evidence"][k]):
                err(f"evidence.{k}", "must be non-empty text")
    if "scores" in result and obj(result["scores"], "scores", DIMENSIONS):
        for k in DIMENSIONS:
            if k in result["scores"] and not (_is_int(result["scores"][k]) and 0 <= result["scores"][k] <= 4):
                err(f"scores.{k}", "must be a whole number 0..4")
    if "overall" in result and not (_is_int(result["overall"]) and 0 <= result["overall"] <= 100):
        err("overall", "must be a whole number 0..100")
    return errors


# ---------------------------------------------------------------- anchors (section 4 of the protocol)


def recall(result):
    """Weighted share of the reference list that the note covers: core items weigh 2, the others 1."""
    lost = {o["ref_id"]: (1.0 if o["coverage"] == "missed" else 0.5) for o in result["omissions"]}
    total = sum(2 if r["core"] else 1 for r in result["reference"])
    kept = sum((2 if r["core"] else 1) * (1.0 - lost.get(r["id"], 0.0)) for r in result["reference"])
    return kept / total


def caps(result):
    """The highest score each dimension may have, counted from the lists of a VALID answer."""
    core = {r["id"] for r in result["reference"] if r["core"]}
    tasks = {r["id"] for r in result["reference"] if r["kind"] == "task"}
    rc = recall(result)
    if rc >= 0.90 and not any(o["ref_id"] in core for o in result["omissions"]):
        coverage = 4
    else:
        coverage = 3 if rc >= 0.75 else 2 if rc >= 0.50 else 1 if rc >= 0.25 else 0

    major = sum(1 for f in result["fabrications"] if f["severity"] == "major")
    minor = len(result["fabrications"]) - major
    if major == 0:
        faithfulness = 4 if minor == 0 else 3 if minor <= 2 else 2 if minor <= 4 else 1
    elif major == 1:
        faithfulness = 2 if minor <= 4 else 1
    else:
        faithfulness = 1 if major <= 3 else 0

    # a missed or invented task costs 2 points, a task without its owner or due costs 1
    points = sum(2 if o["coverage"] == "missed" else 1 for o in result["omissions"] if o["ref_id"] in tasks)
    points += 2 * sum(1 for f in result["fabrications"] if f["category"] == "task")
    task_score = 4 if points == 0 else 3 if points == 1 else 2 if points <= 3 else 1 if points <= 7 else 0

    hard = sum(d["count"] for d in result["format_defects"] if d["category"] in HARD_FORMAT_DEFECTS)
    other = sum(d["count"] for d in result["format_defects"]) - hard
    if hard:
        formatting = 2 if other <= 2 else 1
    else:
        formatting = 4 if other == 0 else 3 if other <= 2 else 2 if other <= 5 else 1
    return {"coverage": coverage, "faithfulness": faithfulness, "tasks": task_score, "formatting": formatting}


def overall_of(scores):
    return sum(WEIGHTS[d] * scores[d] for d in DIMENSIONS)


def _enum(value, allowed):
    """Allow-list gate of the public output: only a closed-enum value passes, anything else stops the run."""
    if not isinstance(value, str) or value not in allowed:
        raise InputError("public output: a value outside its closed list")
    return value


def _public_label(label):
    if label is None:
        return None
    if not (isinstance(label, str) and LABEL_RE.match(label)):
        raise InputError("label must match " + LABEL_RE.pattern)
    return label


def public_record(result, label=None):
    """Numbers and category names of an answer: the only part that may leave the encrypted image.

    An allow-list: the record is built from scratch out of whole numbers, booleans, closed-enum names and the
    operator's label. No string of the answer is copied (not even `meeting`), and an answer that is not valid
    is refused before anything is built.
    """
    if validate_result(result):
        raise InputError("public output: not a valid judge answer (run validate)")
    label = _public_label(label)
    limit = caps(result)
    scores = {d: min(result["scores"][d], limit[d]) for d in DIMENSIONS}
    flags = [f"{d}_above_cap" for d in DIMENSIONS if result["scores"][d] > limit[d]]
    if result["overall"] != overall_of(result["scores"]):
        flags.append("overall_mismatch")
    kinds = {r["id"]: _enum(r["kind"], REFERENCE_KINDS) for r in result["reference"]}
    core = {r["id"] for r in result["reference"] if r["core"]}
    omissions = {}
    for o in result["omissions"]:
        omissions.setdefault(kinds[o["ref_id"]], {"missed": 0, "partial": 0})[_enum(o["coverage"], COVERAGES)] += 1
    fabrications = {}
    for f in result["fabrications"]:
        cell = fabrications.setdefault(_enum(f["category"], FABRICATION_CATEGORIES), {"major": 0, "minor": 0})
        cell[_enum(f["severity"], SEVERITIES)] += 1
    reference = {}
    for kind in kinds.values():
        reference[kind] = reference.get(kind, 0) + 1
    return {
        "schema": PUBLIC_SCHEMA,
        "protocol_version": PROTOCOL,
        "label": label,
        "scores": scores,
        "overall": overall_of(scores),
        "recall": round(recall(result), 2),
        "reference": reference,
        "omissions": omissions,
        "core_omissions": sum(1 for o in result["omissions"] if o["ref_id"] in core),
        "fabrications": fabrications,
        "format_defects": {_enum(d["category"], FORMAT_DEFECTS): int(d["count"]) for d in result["format_defects"]},
        "flags": flags,
    }


# ---------------------------------------------------------------- runs of one note (section 8)


def _norm(text):
    return " ".join(text.lower().split())


def _confirmed_fabrications(results):
    """Fabrications named by more than half of the runs. Two runs name the same one when one quote holds the other."""
    clusters = []
    for run, result in enumerate(results):
        for f in result["fabrications"]:
            q = _norm(f["notes_quote"])
            for c in clusters:
                if any(q in other or other in q for other in c["quotes"]):
                    break
            else:
                c = {"quotes": [], "runs": set(), "severities": [], "categories": []}
                clusters.append(c)
            c["quotes"].append(q)
            c["runs"].add(run)
            c["severities"].append(_enum(f["severity"], SEVERITIES))
            c["categories"].append(_enum(f["category"], FABRICATION_CATEGORIES))
    out = {"major": 0, "minor": 0, "by_category": {}, "single_run": 0}
    for c in clusters:
        if 2 * len(c["runs"]) <= len(results):
            out["single_run"] += 1
            continue
        severity = "major" if 2 * c["severities"].count("major") >= len(c["severities"]) else "minor"
        category = max(sorted(set(c["categories"])), key=c["categories"].count)
        out[severity] += 1
        out["by_category"].setdefault(category, {"major": 0, "minor": 0})[severity] += 1
    return out


def aggregate(results, label=None):
    """Median, spread and verdict over the runs (VALID answers) of one note for one meeting."""
    if len(results) < MIN_RUNS or len(results) % 2 == 0:
        raise InputError(f"aggregate needs an odd number of runs, at least {MIN_RUNS}")
    if len({r["meeting"] for r in results}) != 1:
        raise InputError("aggregate: the runs are not of one meeting")
    records = [public_record(r) for r in results]  # validates every run first
    label = _public_label(label)
    n = len(records)

    def spread(values):
        return {"median": statistics.median_low(values), "spread": max(values) - min(values)}

    scores = {d: spread([rec["scores"][d] for rec in records]) for d in DIMENSIONS}
    overall = spread([rec["overall"] for rec in records])
    omissions = {}
    for kind in REFERENCE_KINDS:
        counts = [sum(rec["omissions"].get(kind, {}).values()) for rec in records]
        if any(counts):
            omissions[kind] = statistics.median_low(counts)
    defects = {}
    for rec in records:
        for category in rec["format_defects"]:
            defects[category] = defects.get(category, 0) + 1
    confirmed = _confirmed_fabrications(results)
    core_runs = sum(1 for rec in records if rec["core_omissions"])
    unstable = (overall["spread"] > UNSTABLE_OVERALL_SPREAD
                or any(scores[d]["spread"] > UNSTABLE_DIMENSION_SPREAD for d in DIMENSIONS))
    if overall["median"] < FAIL_OVERALL or confirmed["major"] >= 2 or scores["coverage"]["median"] <= 1:
        verdict = "fail"
    elif (overall["median"] >= PASS_OVERALL and confirmed["major"] == 0 and 2 * core_runs <= n
          and scores["formatting"]["median"] >= 3 and not unstable):
        verdict = "pass"
    else:
        verdict = "needs_work"
    return {
        "schema": PUBLIC_SCHEMA,
        "protocol_version": PROTOCOL,
        "label": label,
        "runs": n,
        "scores": scores,
        "overall": overall,
        "omissions": omissions,
        "core_omission_runs": core_runs,
        "fabrications_confirmed": confirmed,
        "format_defect_runs": defects,
        "flags": sorted({f for rec in records for f in rec["flags"]}),
        "unstable": unstable,
        "verdict": verdict,
    }


MARKDOWN_HEADER = ("| Meeting | Runs | Overall | Coverage | Faithfulness | Tasks | Formatting | Omissions | "
                   "Fabrications (major/minor) | Format defects | Verdict |\n|---|---|---|---|---|---|---|---|---|---|---|")


def markdown_row(agg):
    def cell(v):
        return "%d ± %d" % (v["median"], v["spread"])

    conf = agg["fabrications_confirmed"]
    omissions = ", ".join("%s %d" % kv for kv in sorted(agg["omissions"].items())) or "0"
    defects = ", ".join(sorted(agg["format_defect_runs"])) or "none"
    verdict = agg["verdict"] + (" (unstable)" if agg["unstable"] else "")
    return "| %s | %d | %s | %s | %s | %s | %s | %s | %d/%d | %s | %s |" % (
        agg["label"] or "-", agg["runs"], cell(agg["overall"]), cell(agg["scores"]["coverage"]),
        cell(agg["scores"]["faithfulness"]), cell(agg["scores"]["tasks"]), cell(agg["scores"]["formatting"]),
        omissions, conf["major"], conf["minor"], defects, verdict)


# ---------------------------------------------------------------- judge control (section 9)


def _assign(wanted, found, fits):
    """True when every wanted item can take a different found item (sizes are tiny: plain backtracking)."""
    if not wanted:
        return True
    for i, f in enumerate(found):
        if fits(wanted[0], f) and _assign(wanted[1:], found[:i] + found[i + 1:], fits):
            return True
    return False


def _caught(wanted, found, fits):
    """How many of the wanted items the answer names, each by a different entry."""
    best = 0
    for size in range(len(wanted), 0, -1):
        if any(_assign(list(part), found, fits) for part in _subsets(wanted, size)):
            best = size
            break
    return best


def _subsets(seq, size):
    if size == 0:
        yield ()
        return
    for i in range(len(seq) - size + 1):
        for rest in _subsets(seq[i + 1:], size - 1):
            yield (seq[i],) + rest


def _options(value):
    return [value] if isinstance(value, str) else list(value)


def check_trap(result, expected):
    """Compare a VALID answer for a trap note with what was planted. Returns counts only."""
    try:
        if expected["schema"] != 1 or expected["protocol_version"] != PROTOCOL:
            raise InputError("trap: schema or protocol version not supported")
        if expected.get("meeting") not in (None, result["meeting"]):
            raise InputError("trap: the answer is for another meeting")
        kinds = {r["id"]: r["kind"] for r in result["reference"]}
        fab = (expected["fabrications"], result["fabrications"],
               lambda w, f: f["category"] in _options(w["category"]) and f["severity"] == w["severity"])
        omi = (expected["omissions"], result["omissions"],
               lambda w, o: kinds[o["ref_id"]] == w["kind"] and o["coverage"] in _options(w["coverage"]))
        named = {d["category"] for d in result["format_defects"]}
        out = {
            "fabrications": {"caught": _caught(*fab), "planted": len(fab[0])},
            "omissions": {"caught": _caught(*omi), "planted": len(omi[0])},
            "format_defects": {"caught": sum(1 for c in expected["format_defects"] if c in named),
                               "planted": len(expected["format_defects"])},
        }
    except (KeyError, TypeError):
        raise InputError("trap: the expected file is malformed")
    out["passed"] = all(v["caught"] == v["planted"] for v in out.values())
    return out


# ---------------------------------------------------------------- command line


def _load(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        raise InputError(f"unreadable: {path} ({type(e).__name__})")


def _valid(path):
    result = _load(path)
    errors = validate_result(result)
    if errors:
        raise InputError(f"not a valid judge answer: {path} ({len(errors)} errors; run validate)")
    return result


def main(argv=None):
    ap = argparse.ArgumentParser(prog="validate_judge_result.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("validate")
    v.add_argument("--segments", type=int, help="number of lines of segments.jsonl")
    v.add_argument("--meeting", help="id from meta.json")
    v.add_argument("results", nargs="+")
    p = sub.add_parser("public")
    p.add_argument("--label")
    p.add_argument("result")
    a = sub.add_parser("aggregate")
    a.add_argument("--label")
    a.add_argument("--markdown", action="store_true", help="print a table row instead of JSON")
    a.add_argument("results", nargs="+")
    t = sub.add_parser("check-trap")
    t.add_argument("--expected", required=True)
    t.add_argument("result")
    try:
        args = ap.parse_args(argv)
    except SystemExit:
        return 2
    try:
        if args.cmd == "validate":
            bad = 0
            for path in args.results:
                errors = validate_result(_load(path), args.segments, args.meeting)
                bad += 1 if errors else 0
                print(("FAIL " if errors else "OK   ") + path)
                for e in errors:
                    print(f"  {e}")
            print(f"{len(args.results) - bad}/{len(args.results)} answers valid")
            return 1 if bad else 0
        if args.cmd == "public":
            print(json.dumps(public_record(_valid(args.result), args.label), ensure_ascii=False, indent=2))
            return 0
        if args.cmd == "aggregate":
            if len({os.path.realpath(path) for path in args.results}) != len(args.results):
                raise InputError("aggregate: the same answer file is given more than once")
            agg = aggregate([_valid(path) for path in args.results], args.label)
            print(MARKDOWN_HEADER + "\n" + markdown_row(agg) if args.markdown
                  else json.dumps(agg, ensure_ascii=False, indent=2))
            return 0
        outcome = check_trap(_valid(args.result), _load(args.expected))
        print("trap %s: fabrications %d/%d, omissions %d/%d, format defects %d/%d" % (
            "caught" if outcome["passed"] else "MISSED",
            outcome["fabrications"]["caught"], outcome["fabrications"]["planted"],
            outcome["omissions"]["caught"], outcome["omissions"]["planted"],
            outcome["format_defects"]["caught"], outcome["format_defects"]["planted"]))
        return 0 if outcome["passed"] else 1
    except InputError as e:
        print(f"validate_judge_result: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
