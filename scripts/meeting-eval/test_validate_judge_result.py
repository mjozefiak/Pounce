import contextlib
import copy
import io
import json
import os
import tempfile
import unittest

import validate_judge_result as vj

HERE = os.path.dirname(os.path.abspath(__file__))
EXAMPLES = os.path.join(HERE, "examples", "fable-judge")


def example(name):
    with open(os.path.join(EXAMPLES, name), "r", encoding="utf-8") as f:
        return json.load(f)


def example_text(name):
    with open(os.path.join(EXAMPLES, name), "r", encoding="utf-8") as f:
        return f.read()


def example_segments():
    return [json.loads(line) for line in example_text("segments.jsonl").splitlines()]


def notes_for_judge(text, has_title):
    """fable-judge.md section 2: drop the `# <title>` line and the empty line the export put before the notes."""
    if not has_title:
        return text
    head, sep, rest = text.partition("\n")
    assert head.startswith("# ") and rest.startswith("\n"), "export header missing"
    return rest[1:]


def transcript_for_judge(segments):
    """fable-judge.md section 2: `[line number] label: text`, no times; an empty segment keeps its number."""
    return [f"[{i}] {s['speaker_label'] or '?'}: {s['text']}" for i, s in enumerate(segments) if s["text"].strip()]


def valid_result():
    return {
        "protocol_version": 1,
        "meeting": "synthetic-01",
        "reference": [
            {"id": "r1", "kind": "decision", "text": "synthetic decision", "owner": None, "due": None, "segment": 2, "core": True},
            {"id": "r2", "kind": "task", "text": "synthetic task", "owner": "Anna", "due": "Friday", "segment": 3, "core": True},
            {"id": "r3", "kind": "finding", "text": "synthetic finding", "owner": None, "due": None, "segment": 0, "core": False},
            {"id": "r4", "kind": "context", "text": "synthetic context", "owner": None, "due": None, "segment": 1, "core": False},
        ],
        "omissions": [],
        "fabrications": [],
        "format_defects": [],
        "evidence": {d: "synthetic evidence" for d in vj.DIMENSIONS},
        "scores": {d: 4 for d in vj.DIMENSIONS},
        "overall": 100,
    }


def fabrication(category="fact", severity="major", quote="synthetic invented sentence"):
    return {"category": category, "severity": severity, "notes_quote": quote, "why": "synthetic reason", "segment": None}


def run_main(argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = vj.main(argv)
    return code, out.getvalue(), err.getvalue()


class ValidateResultTests(unittest.TestCase):
    def test_valid_result(self):
        self.assertEqual(vj.validate_result(valid_result()), [])

    def test_examples_are_valid(self):
        meta = example("meta.json")
        for name in ("result.example.json", "result-trap.example.json"):
            self.assertEqual(vj.validate_result(example(name), meta["segment_count"], str(meta["id"])), [], name)

    def test_missing_and_unknown_keys_are_named(self):
        r = valid_result()
        del r["fabrications"]
        r["verdict"] = "pass"
        del r["scores"]["tasks"]
        errors = vj.validate_result(r)
        self.assertIn("fabrications: missing", errors)
        self.assertIn("result: 1 unknown key(s)", errors)
        self.assertIn("scores.tasks: missing", errors)

    def test_not_an_object(self):
        self.assertEqual(vj.validate_result([]), ["result: must be a JSON object"])

    def test_enums_and_ranges(self):
        r = valid_result()
        r["protocol_version"] = 2
        r["reference"][0]["kind"] = "topic"
        r["fabrications"] = [fabrication(category="invented", severity="huge")]
        r["format_defects"] = [{"category": "ugly", "count": 0, "why": "x"}]
        r["scores"]["coverage"] = 5
        r["scores"]["tasks"] = 3.0  # JSON Schema "integer" would take it; the validator does not
        r["overall"] = True
        errors = vj.validate_result(r)
        for path in ("protocol_version", "reference[0].kind", "fabrications[0].category", "fabrications[0].severity",
                     "format_defects[0].category", "format_defects[0].count", "scores.coverage", "scores.tasks",
                     "overall"):
            self.assertTrue(any(e.startswith(path + ":") for e in errors), path)

    def test_references_between_lists(self):
        r = valid_result()
        r["reference"][1]["id"] = "r1"
        r["reference"][2]["owner"] = "Anna"
        r["omissions"] = [{"ref_id": "r9", "coverage": "missed", "why": "x"},
                          {"ref_id": "r3", "coverage": "partial", "why": "x"},
                          {"ref_id": "r3", "coverage": "missed", "why": "x"}]
        errors = vj.validate_result(r)
        self.assertIn("reference[1].id: duplicate id", errors)
        self.assertIn("reference[2].owner: must be null unless kind is task", errors)
        self.assertIn("omissions[0].ref_id: is not an id of the reference list", errors)
        self.assertIn("omissions[2].ref_id: listed twice", errors)

    def test_segment_bounds_and_meeting(self):
        r = valid_result()
        r["fabrications"] = [fabrication()]
        r["fabrications"][0]["segment"] = 7
        errors = vj.validate_result(r, segment_count=3, meeting="another")
        self.assertIn("reference[1].segment: is beyond the last segment", errors)
        self.assertIn("fabrications[0].segment: is beyond the last segment", errors)
        self.assertIn("meeting: is not the meeting that was judged", errors)

    def test_errors_never_quote_the_answer(self):
        r = valid_result()
        r["reference"][0]["text"] = "SECRET-TEXT"
        r["reference"][0]["kind"] = "SECRET-KIND"
        r["extra-SECRET"] = 1
        r["fabrications"] = [fabrication(quote="SECRET-QUOTE", category="SECRET-CAT")]
        r["scores"]["SECRET-DIMENSION"] = 4
        errors = vj.validate_result(r)
        self.assertIn("scores: 1 unknown key(s)", errors)
        self.assertTrue(errors)
        self.assertFalse(any("SECRET" in e for e in errors))

    def test_validator_and_schema_file_agree(self):
        with open(os.path.join(HERE, "fable-judge-result.schema.json"), "r", encoding="utf-8") as f:
            schema = json.load(f)
        props = schema["properties"]
        self.assertEqual(tuple(schema["required"]), vj.TOP_KEYS)
        self.assertEqual(props["protocol_version"]["const"], vj.PROTOCOL)
        self.assertEqual(tuple(props["reference"]["items"]["properties"]["kind"]["enum"]), vj.REFERENCE_KINDS)
        self.assertEqual(tuple(props["omissions"]["items"]["properties"]["coverage"]["enum"]), vj.COVERAGES)
        fab = props["fabrications"]["items"]["properties"]
        self.assertEqual(tuple(fab["category"]["enum"]), vj.FABRICATION_CATEGORIES)
        self.assertEqual(tuple(fab["severity"]["enum"]), vj.SEVERITIES)
        self.assertEqual(tuple(props["format_defects"]["items"]["properties"]["category"]["enum"]), vj.FORMAT_DEFECTS)
        self.assertEqual(tuple(props["scores"]["required"]), vj.DIMENSIONS)
        self.assertEqual(tuple(props["evidence"]["required"]), vj.DIMENSIONS)


class ProtocolDocumentTests(unittest.TestCase):
    """fable-judge.md is the source of the rubric and the prompt; it must name what the validator accepts."""

    def setUp(self):
        with open(os.path.join(HERE, "fable-judge.md"), "r", encoding="utf-8") as f:
            self.text = f.read()

    def between(self, name):
        return self.text.split(f"<!-- {name}-BEGIN -->", 1)[1].split(f"<!-- {name}-END -->", 1)[0]

    def test_version_matches(self):
        self.assertIn(f"\njudge_protocol_version: {vj.PROTOCOL}\n", self.text)
        self.assertIn(f'"protocol_version": {vj.PROTOCOL},', self.between("JUDGE-PROMPT"))

    def test_prompt_has_every_placeholder_once_and_every_key(self):
        prompt = self.between("JUDGE-PROMPT")
        for name in ("RUBRIC", "MEETING", "SEGMENTS", "NOTES"):
            self.assertEqual(prompt.count("{{%s}}" % name), 1, name)
        self.assertNotIn("{{LANGUAGE}}", prompt)  # the export has no language; the judge reads it off the transcript
        for key in vj.TOP_KEYS:
            self.assertIn(f'"{key}":', prompt)
        for group in (vj.REFERENCE_KINDS, vj.FABRICATION_CATEGORIES, vj.FORMAT_DEFECTS, vj.COVERAGES, vj.SEVERITIES):
            self.assertIn("|".join(group), prompt)

    def test_rubric_names_every_category_and_the_weights(self):
        rubric = self.between("JUDGE-RUBRIC")
        for name in vj.REFERENCE_KINDS + vj.FABRICATION_CATEGORIES + vj.FORMAT_DEFECTS:
            self.assertIn(name, rubric)
        for i, d in enumerate(vj.DIMENSIONS, 1):
            self.assertIn(f"{i}. {d} (waga {vj.WEIGHTS[d]})", rubric)
        self.assertIn("OVERALL = " + " + ".join(f"{vj.WEIGHTS[d]}*{d}" for d in vj.DIMENSIONS), rubric)

    def test_thresholds_are_marked_as_a_proposal(self):
        section = self.text.split("## 5. Skala i progi", 1)[1].split("## 6.", 1)[0]
        self.assertIn("**Progi to propozycja bez danych.**", section)
        self.assertIn("po pierwszej serii", section)


class ExportShapeTests(unittest.TestCase):
    """The example is in the shape `meeting-export` 1 writes (fable-judge.md section 2), not one of our own."""

    def test_json_files_are_compact_with_sorted_keys(self):
        for name in ("meta.json", "speakers.json"):
            text = example_text(name)
            self.assertEqual(text, json.dumps(json.loads(text), ensure_ascii=False, sort_keys=True, separators=(",", ":")))
        for line in example_text("segments.jsonl").splitlines():
            self.assertEqual(line, json.dumps(json.loads(line), ensure_ascii=False, sort_keys=True, separators=(",", ":")))
        self.assertTrue(example_text("segments.jsonl").endswith("\n"))

    def test_segments(self):
        segments, meta = example_segments(), example("meta.json")
        self.assertEqual(len(segments), meta["segment_count"])
        starts = [s["start_ms"] for s in segments]
        self.assertEqual(starts, sorted(starts))
        for s in segments:
            self.assertTrue(vj._is_int(s["start_ms"]) and vj._is_int(s["end_ms"]) and vj._is_int(s["id"]))
            self.assertIn(s["channel"], ("mic", "system"))
            self.assertTrue(s["speaker_label"] is None or isinstance(s["speaker_label"], str))
            self.assertTrue(s["speaker_is_self"] is None or isinstance(s["speaker_is_self"], bool))
            self.assertNotIn("meeting_id", s)
            for old in ("index", "start", "end", "speaker"):
                self.assertNotIn(old, s)

    def test_speakers_use_integer_is_self(self):
        speakers, meta = example("speakers.json"), example("meta.json")
        self.assertEqual(len(speakers), meta["speaker_count"])
        by_id = {s["id"]: s for s in speakers}
        for s in speakers:
            self.assertEqual(set(s), {"id", "label", "is_self", "source_channel"})
            self.assertIn(s["is_self"], (0, 1))
            self.assertNotIsInstance(s["is_self"], bool)
        for seg in example_segments():
            self.assertEqual(seg["speaker_label"], by_id[seg["speaker_id"]]["label"])
            self.assertEqual(seg["speaker_is_self"], bool(by_id[seg["speaker_id"]]["is_self"]))

    def test_meta_has_no_title_language_or_participants(self):
        meta = example("meta.json")
        for absent in ("title", "notes_markdown", "language", "participants", "synthetic", "judge_consent"):
            self.assertNotIn(absent, meta)
        self.assertEqual(meta["tool"], {"name": "meeting-export", "version": "1"})
        self.assertTrue(vj._is_int(meta["id"]) and vj.ID_RE.match(str(meta["id"])))
        self.assertTrue(meta["has_title"] and meta["has_notes"])

    def test_notes_carry_the_export_title_header_which_the_judge_never_sees(self):
        has_title = example("meta.json")["has_title"]
        for name in ("notes.md", "notes-trap.md"):
            text = example_text(name)
            self.assertTrue(text.startswith("# "), name)
            self.assertFalse(text.endswith("\n"), name)  # notes_markdown verbatim, no trailing newline
            body = notes_for_judge(text, has_title)
            self.assertNotIn(text.split("\n", 1)[0], body)
            self.assertFalse(body.startswith("#"), name)
        trap = " ".join(notes_for_judge(example_text("notes-trap.md"), has_title).split())
        for f in example("result-trap.example.json")["fabrications"]:
            self.assertIn(" ".join(f["notes_quote"].split()), trap)  # no unverified_quote

    def test_transcript_for_the_prompt_has_line_numbers_labels_and_no_times(self):
        lines = transcript_for_judge(example_segments())
        self.assertEqual(lines[5], "[5] Ola: To ustalmy: wydajemy w czwartek 12 marca, nie w poniedziałek.")
        self.assertEqual(len(lines), example("meta.json")["segment_count"])
        for line, seg in zip(lines, example_segments()):
            self.assertNotIn(str(seg["start_ms"]) + " ", line + " ")
        self.assertEqual(transcript_for_judge([{"speaker_label": None, "text": "x"}]), ["[0] ?: x"])


class AnchorTests(unittest.TestCase):
    def test_clean_answer_keeps_full_scores(self):
        self.assertEqual(vj.caps(valid_result()), {d: 4 for d in vj.DIMENSIONS})
        self.assertEqual(vj.overall_of({d: 4 for d in vj.DIMENSIONS}), 100)

    def test_coverage_cap_follows_recall(self):
        r = valid_result()  # weights: r1 2, r2 2, r3 1, r4 1
        r["omissions"] = [{"ref_id": "r3", "coverage": "partial", "why": "x"}]
        self.assertAlmostEqual(vj.recall(r), 5.5 / 6)
        self.assertEqual(vj.caps(r)["coverage"], 4)
        r["omissions"] = [{"ref_id": "r1", "coverage": "partial", "why": "x"}]  # 5/6 and a core item
        self.assertEqual(vj.caps(r)["coverage"], 3)
        r["omissions"] = [{"ref_id": "r1", "coverage": "missed", "why": "x"}]  # 4/6
        self.assertEqual(vj.caps(r)["coverage"], 2)
        r["omissions"] = [{"ref_id": i, "coverage": "missed", "why": "x"} for i in ("r1", "r2", "r3", "r4")]
        self.assertEqual(vj.caps(r)["coverage"], 0)

    def test_faithfulness_cap_counts_fabrications(self):
        r = valid_result()
        for major, minor, want in ((0, 2, 3), (0, 4, 2), (0, 5, 1), (1, 0, 2), (1, 5, 1), (3, 0, 1), (4, 0, 0)):
            r["fabrications"] = ([fabrication(quote=f"a{i}") for i in range(major)]
                                 + [fabrication(severity="minor", quote=f"b{i}") for i in range(minor)])
            self.assertEqual(vj.caps(r)["faithfulness"], want, (major, minor))

    def test_tasks_cap(self):
        r = valid_result()
        r["omissions"] = [{"ref_id": "r2", "coverage": "partial", "why": "x"}]
        self.assertEqual(vj.caps(r)["tasks"], 3)
        r["omissions"] = [{"ref_id": "r2", "coverage": "missed", "why": "x"}]
        self.assertEqual(vj.caps(r)["tasks"], 2)
        r["fabrications"] = [fabrication(category="task")]
        self.assertEqual(vj.caps(r)["tasks"], 1)
        r["omissions"] = [{"ref_id": "r1", "coverage": "missed", "why": "x"}]  # a decision is not a task
        r["fabrications"] = []
        self.assertEqual(vj.caps(r)["tasks"], 4)

    def test_timestamps_and_author_markers_cap_formatting_at_two(self):
        r = valid_result()
        for category in vj.HARD_FORMAT_DEFECTS:
            r["format_defects"] = [{"category": category, "count": 1, "why": "x"}]
            self.assertEqual(vj.caps(r)["formatting"], 2, category)
        r["format_defects"].append({"category": "duplicate", "count": 3, "why": "x"})
        self.assertEqual(vj.caps(r)["formatting"], 1)
        r["format_defects"] = [{"category": "verbosity", "count": 2, "why": "x"}]
        self.assertEqual(vj.caps(r)["formatting"], 3)
        r["format_defects"] = [{"category": "verbosity", "count": 6, "why": "x"}]
        self.assertEqual(vj.caps(r)["formatting"], 1)


class PublicRecordTests(unittest.TestCase):
    def test_trap_example_numbers(self):
        rec = vj.public_record(example("result-trap.example.json"), label="M01")
        self.assertEqual(rec["label"], "M01")
        self.assertEqual(rec["scores"], {"coverage": 3, "faithfulness": 1, "tasks": 1, "formatting": 2})
        self.assertEqual(rec["overall"], 46)
        self.assertEqual(rec["recall"], 0.82)
        self.assertEqual(rec["omissions"], {"task": {"missed": 1, "partial": 0}})
        self.assertEqual(rec["core_omissions"], 1)
        self.assertEqual(rec["fabrications"], {"number_or_date": {"major": 1, "minor": 0}, "task": {"major": 1, "minor": 0}})
        self.assertEqual(rec["format_defects"], {"timestamp_in_notes": 1, "author_marker": 1})
        self.assertEqual(rec["flags"], [])

    def test_scores_above_the_cap_are_lowered_and_flagged(self):
        r = valid_result()
        r["fabrications"] = [fabrication()]
        r["format_defects"] = [{"category": "timestamp_in_notes", "count": 4, "why": "x"}]
        rec = vj.public_record(r)
        self.assertEqual(rec["scores"]["faithfulness"], 2)
        self.assertEqual(rec["scores"]["formatting"], 2)
        self.assertEqual(rec["overall"], 8 * 4 + 9 * 2 + 3 * 4 + 5 * 2)
        self.assertEqual(rec["flags"], ["faithfulness_above_cap", "formatting_above_cap"])

    def test_overall_mismatch_is_flagged(self):
        r = valid_result()
        r["overall"] = 90
        rec = vj.public_record(r)
        self.assertEqual(rec["overall"], 100)
        self.assertEqual(rec["flags"], ["overall_mismatch"])

    def test_public_record_holds_no_text_of_the_answer(self):
        r = example("result-trap.example.json")
        out = json.dumps([vj.public_record(r, label="M01"), vj.aggregate([r, r, r], label="M01")], ensure_ascii=False)
        texts = [x["text"] for x in r["reference"]] + [x["why"] for x in r["omissions"]]
        texts += [f[k] for f in r["fabrications"] for k in ("notes_quote", "why")]
        texts += [d["why"] for d in r["format_defects"]] + list(r["evidence"].values())
        texts += [x[k] for x in r["reference"] for k in ("owner", "due") if x[k]] + [r["meeting"]]
        for t in texts:
            self.assertNotIn(t, out)


    def test_no_free_text_of_the_answer_reaches_the_public_output(self):
        """Every string the judge writes holds a unique sentinel; none may reach `public`, `aggregate` or the table."""
        def answer(run):
            r = valid_result()
            r["meeting"] = "sentinelmeeting"
            for i, item in enumerate(r["reference"]):
                item["text"] = f"SENTINEL-{run}-REF-TEXT-{i}"
                if item["kind"] == "task":
                    item["owner"], item["due"] = f"SENTINEL-{run}-OWNER-{i}", f"SENTINEL-{run}-DUE-{i}"
            r["omissions"] = [{"ref_id": "r2", "coverage": "partial", "why": f"SENTINEL-{run}-OMISSION-WHY"}]
            r["fabrications"] = [
                fabrication("task", "major", f"SENTINEL-{run}-QUOTE-A same sentence"),
                fabrication("fact", "minor", f"SENTINEL-{run}-QUOTE-B"),
            ]
            for j, f in enumerate(r["fabrications"]):
                f["why"] = f"SENTINEL-{run}-FAB-WHY-{j}"
            r["format_defects"] = [{"category": "duplicate", "count": 2, "why": f"SENTINEL-{run}-DEFECT-WHY"}]
            r["evidence"] = {d: f"SENTINEL-{run}-EVIDENCE-{d}" for d in vj.DIMENSIONS}
            self.assertEqual(vj.validate_result(r), [])
            return r

        runs = [answer(n) for n in range(3)]
        outputs = [json.dumps(vj.public_record(r), ensure_ascii=False) for r in runs]
        outputs.append(json.dumps(vj.public_record(runs[0], label="M01"), ensure_ascii=False))
        agg = vj.aggregate(runs)
        outputs += [json.dumps(agg, ensure_ascii=False), vj.markdown_row(agg)]
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for n, r in enumerate(runs):
                paths.append(os.path.join(tmp, f"run-{n + 1}.json"))
                with open(paths[-1], "w", encoding="utf-8") as f:
                    json.dump(r, f)
            for argv in (["public", paths[0]], ["aggregate"] + paths, ["aggregate", "--markdown"] + paths):
                code, out, err = run_main(argv)
                self.assertEqual(code, 0, argv)
                outputs += [out, err]
        for out in outputs:
            self.assertNotIn("SENTINEL", out)
            self.assertNotIn("sentinelmeeting", out)
        self.assertIsNone(vj.public_record(runs[0])["label"])  # the label never defaults to the answer's meeting

    def test_public_output_is_an_allow_list(self):
        r = valid_result()
        r["format_defects"] = [{"category": "SENTINEL-not-a-category", "count": 1, "why": "x"}]
        with self.assertRaises(vj.InputError):
            vj.public_record(r)  # an answer outside the closed lists is refused, not passed through
        with self.assertRaises(vj.InputError):
            vj._enum("SENTINEL", vj.FORMAT_DEFECTS)
        for bad in ("", " M01", "M01\nsecret", "x" * 41, "a/b"):
            with self.assertRaises(vj.InputError):
                vj.public_record(valid_result(), label=bad)
        self.assertEqual(vj.public_record(valid_result(), label="M01 before")["label"], "M01 before")
        self.assertEqual(run_main(["public", "--label", "bad\nlabel", os.path.join(EXAMPLES, "result.example.json")])[0], 2)


class AggregateTests(unittest.TestCase):
    def test_three_clean_runs_pass(self):
        r = example("result.example.json")
        agg = vj.aggregate([r, r, r], label="M01")
        self.assertEqual(agg["verdict"], "pass")
        self.assertEqual(agg["overall"], {"median": 100, "spread": 0})
        self.assertFalse(agg["unstable"])

    def test_trap_runs_fail_with_confirmed_fabrications(self):
        r = example("result-trap.example.json")
        agg = vj.aggregate([r, r, r])
        self.assertEqual(agg["verdict"], "fail")
        self.assertEqual(agg["fabrications_confirmed"]["major"], 2)
        self.assertEqual(agg["omissions"], {"task": 1})
        self.assertEqual(agg["core_omission_runs"], 3)
        self.assertEqual(agg["format_defect_runs"], {"timestamp_in_notes": 3, "author_marker": 3})

    def test_a_fabrication_named_by_one_run_is_not_confirmed(self):
        clean, noisy = valid_result(), valid_result()
        noisy["fabrications"] = [fabrication(severity="minor")]
        noisy["scores"]["faithfulness"], noisy["overall"] = 3, 91
        agg = vj.aggregate([clean, noisy, clean])
        self.assertEqual(agg["fabrications_confirmed"]["minor"], 0)
        self.assertEqual(agg["fabrications_confirmed"]["single_run"], 1)
        self.assertEqual(agg["scores"]["faithfulness"], {"median": 4, "spread": 1})
        self.assertEqual(agg["verdict"], "pass")

    def test_two_runs_quoting_the_same_sentence_confirm_it(self):
        a, b, c = valid_result(), valid_result(), valid_result()
        a["fabrications"] = [fabrication(quote="The limit   grows to 20 thousand rows.")]
        b["fabrications"] = [fabrication(quote="limit grows to 20 thousand", category="number_or_date")]
        agg = vj.aggregate([a, b, c])
        self.assertEqual(agg["fabrications_confirmed"]["major"], 1)
        self.assertEqual(agg["verdict"], "needs_work")  # a, b: faithfulness capped at 2, overall 82, one major

    def test_a_wide_spread_is_unstable_and_cannot_pass(self):
        a, b = valid_result(), valid_result()
        b["scores"]["formatting"], b["overall"] = 2, 90
        agg = vj.aggregate([a, a, b])
        self.assertTrue(agg["unstable"])
        self.assertEqual(agg["verdict"], "needs_work")

    def test_needs_three_runs_of_one_meeting(self):
        r, other = valid_result(), valid_result()
        other["meeting"] = "synthetic-02"
        with self.assertRaises(vj.InputError):
            vj.aggregate([r, r])
        with self.assertRaises(vj.InputError):
            vj.aggregate([r, r, r, r])
        with self.assertRaises(vj.InputError):
            vj.aggregate([r, r, other])

    def test_markdown_row_has_numbers_and_categories_only(self):
        row = vj.markdown_row(vj.aggregate([example("result-trap.example.json")] * 3, label="M01"))
        self.assertEqual(row, "| M01 | 3 | 46 ± 0 | 3 ± 0 | 1 ± 0 | 1 ± 0 | 2 ± 0 | task 1 | 2/0 | "
                              "author_marker, timestamp_in_notes | fail |")
        self.assertEqual(row.count("|"), vj.MARKDOWN_HEADER.splitlines()[0].count("|"))


class TrapTests(unittest.TestCase):
    def test_trap_answer_catches_everything_planted(self):
        outcome = vj.check_trap(example("result-trap.example.json"), example("trap-expected.json"))
        self.assertTrue(outcome["passed"])
        self.assertEqual(outcome["fabrications"], {"caught": 2, "planted": 2})

    def test_clean_answer_misses_the_trap(self):
        outcome = vj.check_trap(example("result.example.json"), example("trap-expected.json"))
        self.assertFalse(outcome["passed"])
        self.assertEqual(outcome["fabrications"]["caught"], 0)
        self.assertEqual(outcome["format_defects"], {"caught": 0, "planted": 2})

    def test_one_finding_cannot_cover_two_planted_errors(self):
        r = example("result-trap.example.json")
        r["fabrications"] = r["fabrications"][:1]
        self.assertEqual(vj.check_trap(r, example("trap-expected.json"))["fabrications"], {"caught": 1, "planted": 2})

    def test_wrong_severity_or_another_meeting(self):
        r = example("result-trap.example.json")
        r["fabrications"][1]["severity"] = "minor"
        self.assertFalse(vj.check_trap(r, example("trap-expected.json"))["passed"])
        r["meeting"] = "synthetic-02"
        with self.assertRaises(vj.InputError):
            vj.check_trap(r, example("trap-expected.json"))
        with self.assertRaises(vj.InputError):
            vj.check_trap(example("result-trap.example.json"), {"schema": 1, "protocol_version": 1})


class MainTests(unittest.TestCase):
    def test_validate_exit_codes(self):
        good = os.path.join(EXAMPLES, "result.example.json")
        code, out, _ = run_main(["validate", "--segments", "14", "--meeting", "901", good])
        self.assertEqual(code, 0)
        self.assertIn("1/1 answers valid", out)
        with tempfile.TemporaryDirectory() as tmp:
            bad = os.path.join(tmp, "bad.json")
            r = copy.deepcopy(valid_result())
            del r["scores"]
            with open(bad, "w", encoding="utf-8") as f:
                json.dump(r, f)
            code, out, _ = run_main(["validate", good, bad])
            self.assertEqual(code, 1)
            self.assertIn("  scores: missing", out)
            self.assertEqual(run_main(["public", bad])[0], 2)
            self.assertEqual(run_main(["validate", os.path.join(tmp, "absent.json")])[0], 2)
        self.assertEqual(run_main([])[0], 2)

    def test_public_aggregate_and_trap_commands(self):
        trap = os.path.join(EXAMPLES, "result-trap.example.json")
        code, out, _ = run_main(["public", "--label", "M01", trap])
        self.assertEqual((code, json.loads(out)["overall"]), (0, 46))
        with tempfile.TemporaryDirectory() as tmp:
            runs = []
            for i in range(3):
                runs.append(os.path.join(tmp, f"run-{i + 1}.json"))
                with open(runs[-1], "w", encoding="utf-8") as f:
                    json.dump(example("result-trap.example.json"), f)
            code, out, _ = run_main(["aggregate", "--markdown", "--label", "M01"] + runs)
            self.assertEqual(code, 0)
            self.assertTrue(out.startswith(vj.MARKDOWN_HEADER))
            self.assertEqual(run_main(["aggregate"] + runs[:2])[0], 2)
            code, _, err = run_main(["aggregate", runs[0], runs[1], runs[0]])
            self.assertEqual(code, 2)
            self.assertIn("more than once", err)
        expected = os.path.join(EXAMPLES, "trap-expected.json")
        code, out, _ = run_main(["check-trap", "--expected", expected, trap])
        self.assertEqual((code, out.strip()), (0, "trap caught: fabrications 2/2, omissions 1/1, format defects 2/2"))
        code, out, _ = run_main(["check-trap", "--expected", expected, os.path.join(EXAMPLES, "result.example.json")])
        self.assertEqual(code, 1)
        self.assertIn("MISSED", out)


if __name__ == "__main__":
    unittest.main()
