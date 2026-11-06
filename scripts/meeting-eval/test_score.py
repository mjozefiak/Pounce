import contextlib
import io
import json
import os
import tempfile
import unittest

import score


def seg(start, end, text, track="mic"):
    return {"track": track, "startMs": start, "endMs": end, "text": text}


def result(segments, **asr_extra):
    asr = {"processingSeconds": 1.0, "rtf": 0.1, "peakFootprintMB": 100.0,
           "deferredSegments": 0, "segments": segments}
    asr.update(asr_extra)
    return {"schema": 1, "recording": "r", "audioSeconds": 10.0,
            "config": {"engine": "e", "language": "pl", "codeVersion": "x"},
            "asr": asr, "diarization": None, "notes": None}


class NormalizeTests(unittest.TestCase):
    def test_basic(self):
        self.assertEqual(score.normalize("  Ala, MA   kota!  "), "ala ma kota")

    def test_polish_diacritics_preserved(self):
        self.assertEqual(score.normalize("Zażółć GĘŚLĄ jaźń"), "zażółć gęślą jaźń")
        self.assertIn("ł", score.normalize("Łódź"))

    def test_nfc(self):
        decomposed = "zé"  # e + combining acute
        self.assertEqual(score.normalize(decomposed), "zé".replace("z", "z"))
        self.assertEqual(score.normalize("ą"), "ą")  # a + ogonek -> ą

    def test_apostrophe_hyphen_separators(self):
        self.assertEqual(score.tokens("don't e-mail"), ["don", "t", "e", "mail"])

    def test_empty(self):
        self.assertEqual(score.tokens(""), [])
        self.assertEqual(score.tokens("..."), [])


class WerCerTests(unittest.TestCase):
    def test_known_wer(self):
        w = score.wer("ala ma kota".split(), "ala ma psa".split())
        self.assertAlmostEqual(w["rate"], 1 / 3)
        self.assertEqual((w["substitutions"], w["deletions"], w["insertions"]), (1, 0, 0))

    def test_deletion_insertion(self):
        w = score.wer("a b c d".split(), "a c d e".split())
        self.assertEqual(w["errors"], 2)
        self.assertEqual((w["substitutions"], w["deletions"], w["insertions"]), (0, 1, 1))

    def test_perfect(self):
        self.assertEqual(score.wer(["a"], ["a"])["rate"], 0)

    def test_empty_reference(self):
        self.assertIsNone(score.wer([], ["a"]))
        self.assertIsNone(score.cer([], ["a"]))
        self.assertIsNone(score.wer([], []))

    def test_empty_hypothesis(self):
        w = score.wer(["a", "b"], [])
        self.assertEqual(w["deletions"], 2)
        self.assertEqual(w["rate"], 1.0)

    def test_cer_known(self):
        c = score.cer(["kot"], ["kit"])
        self.assertAlmostEqual(c["rate"], 1 / 3)
        self.assertEqual(c["substitutions"], 1)
        # spaces counted: "a b" vs "ab" -> one deletion over 3 chars
        c2 = score.cer(["a", "b"], ["ab"])
        self.assertAlmostEqual(c2["rate"], 1 / 3)
        self.assertEqual(c2["deletions"], 1)

    def test_cer_polish(self):
        c = score.cer(["łódź"], ["lodz"])
        self.assertEqual(c["substitutions"], 3)  # diacritics are not folded
        self.assertAlmostEqual(c["rate"], 3 / 4)


class SelectionTests(unittest.TestCase):
    def test_midpoint_selection_and_order(self):
        segs = [seg(5000, 7000, "late"), seg(900, 1200, "edge"),  # mid 1050
                seg(0, 1000, "first"),                            # mid 500
                seg(1900, 2300, "out")]                           # mid 2100
        hyp = score.excerpt_hypothesis(segs, 0, 2000)
        self.assertEqual(hyp, "first edge")

    def test_end_exclusive_start_inclusive(self):
        segs = [seg(1000, 3000, "a"), seg(0, 2000, "b")]  # mids 2000, 1000
        self.assertEqual(score.excerpt_hypothesis(segs, 0, 2000), "b")
        self.assertEqual(score.excerpt_hypothesis(segs, 2000, 4000), "a")

    def test_both_tracks_ordered_by_start(self):
        segs = [seg(2000, 2400, "two", "system"), seg(1000, 1400, "one", "mic")]
        self.assertEqual(score.excerpt_hypothesis(segs, 0, 5000), "one two")


class TermTests(unittest.TestCase):
    def test_recall(self):
        ref = [score.tokens("Kubernetes jest super Kubernetes DHH")]
        hyp = [score.tokens("kubernetes jest super kubernetis")]
        t = score.term_counts(["Kubernetes", "DHH", "Absent"], ref, hyp)
        self.assertEqual(t["Kubernetes"]["ref"], 2)
        self.assertEqual(t["Kubernetes"]["hyp"], 1)
        self.assertAlmostEqual(t["Kubernetes"]["recall"], 0.5)
        self.assertEqual(t["DHH"]["recall"], 0)
        self.assertNotIn("Absent", t)

    def test_recall_capped(self):
        t = score.term_counts(["x"], [["x"]], [["x", "x", "x"]])
        self.assertEqual(t["x"]["recall"], 1.0)

    def test_multiword_term(self):
        t = score.term_counts(["Łódź Fabryczna"], [score.tokens("do Łódź Fabryczna")],
                              [score.tokens("do łódź fabryczna")])
        self.assertEqual(t["Łódź Fabryczna"]["recall"], 1.0)


class SilenceAndLoopTests(unittest.TestCase):
    def test_silence_words(self):
        segs = [seg(500, 1500, "ala ma kota"),   # mid 1000 in [0,4000)
                seg(3900, 4500, "dwa slowa"),    # mid 4200 outside
                seg(6000, 7000, "x y")]          # mid 6500 in [6000,8000)
        rep = score.silence_report(segs, [{"startMs": 0, "endMs": 4000},
                                          {"startMs": 6000, "endMs": 8000},
                                          {"startMs": 9000, "endMs": 10000}])
        self.assertEqual(rep["totalWords"], 5)
        self.assertEqual([s["words"] for s in rep["spans"]], [3, 2, 0])

    def test_token_loop(self):
        self.assertEqual(score.count_loops(["a"] * 5), 1)
        self.assertEqual(score.count_loops(["a"] * 4), 0)
        self.assertEqual(score.count_loops(["a"] * 12), 1)

    def test_phrase_loop(self):
        self.assertEqual(score.count_loops("x y z x y z x y z".split()), 1)
        self.assertEqual(score.count_loops("x y z x y z".split()), 0)
        self.assertEqual(score.count_loops("ab cd ab cd ab cd".split()), 1)

    def test_two_loops(self):
        toks = ["a"] * 5 + ["mid"] + "p q p q p q".split()
        self.assertEqual(score.count_loops(toks), 2)

    def test_loops_per_segment(self):
        segs = [seg(0, 1, "no no no no no"), seg(1, 2, "fine text here")]
        self.assertEqual(score.count_loops_in_segments(segs), 1)


class PipelineTests(unittest.TestCase):
    def make_run(self, root, name, segs, refs=None, **asr_extra):
        rd = os.path.join(root, name)
        os.makedirs(rd, exist_ok=True)
        return rd

    def test_score_recording(self):
        res = result([seg(0, 1000, "ala ma psa"), seg(10000, 11000, "halo halo")])
        res["diarization"] = {"seconds": 30.0, "peakFootprintMB": 900.0, "speakers": 2}
        refs = {"excerpts": [{"startMs": 0, "endMs": 5000, "text": "Ala ma kota"}],
                "terms": ["kota"], "silences": [{"startMs": 9000, "endMs": 12000}]}
        r = score.score_recording(res, refs)
        self.assertAlmostEqual(r["wer"], 1 / 3)
        self.assertEqual(r["termRecall"], 0.0)
        self.assertEqual(r["silenceWords"], 2)
        self.assertEqual(r["diarSpeakers"], 2)
        self.assertEqual(len(r["drift"]), 1)
        self.assertAlmostEqual(r["drift"][0]["wer"], 1 / 3)

    def test_no_refs(self):
        r = score.score_recording(result([seg(0, 1, "a")]), None)
        self.assertFalse(r["hasRefs"])
        self.assertIsNone(r["wer"])
        self.assertIsNone(r["silenceWords"])

    def test_cli_score_and_privacy(self):
        secret = "tajnehaslo"
        with tempfile.TemporaryDirectory() as tmp:
            rd, fd = os.path.join(tmp, "run"), os.path.join(tmp, "refs")
            os.makedirs(rd)
            os.makedirs(fd)
            with open(os.path.join(rd, "a.json"), "w", encoding="utf-8") as f:
                json.dump(result([seg(0, 1000, f"{secret} ma psa")]), f)
            with open(os.path.join(rd, "b.json"), "w", encoding="utf-8") as f:
                json.dump(result([seg(0, 1000, "x")]), f)
            with open(os.path.join(fd, "a.json"), "w", encoding="utf-8") as f:
                json.dump({"excerpts": [{"startMs": 0, "endMs": 5000,
                                         "text": f"{secret} ma kota"}],
                           "terms": ["kota"], "silences": []}, f)
            out_json = os.path.join(tmp, "scored.json")
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = score.main(["score", "--results", rd, "--refs", fd, "--out", out_json])
            text = buf.getvalue()
            self.assertEqual(rc, 0)
            self.assertNotIn(secret, text)
            self.assertIn("no reference file", text)
            self.assertIn("kota", text)  # term names are allowed
            with open(out_json, encoding="utf-8") as f:
                data = json.load(f)
            self.assertNotIn(secret, json.dumps(data, ensure_ascii=False))
            self.assertAlmostEqual(data["recordings"]["a"]["wer"], 1 / 3)
            self.assertIsNone(data["recordings"]["b"]["wer"])


class CompareTests(unittest.TestCase):
    def rec(self, **kw):
        base = {k: None for k, _, _ in score.METRICS}
        base.update(kw)
        return base

    def verdicts(self, b, c):
        cmp = score.compare_runs({"recordings": {"r": b}}, {"recordings": {"r": c}})
        return {r["metric"]: r for r in cmp["rows"]}

    def test_directions(self):
        b = self.rec(wer=0.2, cer=0.1, silenceWords=10, loops=2, rtf=0.1, peakMB=1000,
                     termRecall=0.5, deferredSegments=0)
        c = self.rec(wer=0.1, cer=0.2, silenceWords=10, loops=1, rtf=0.2, peakMB=500,
                     termRecall=0.9, deferredSegments=3)
        v = self.verdicts(b, c)
        self.assertEqual(v["wer"]["verdict"], "improved")
        self.assertEqual(v["cer"]["verdict"], "regressed")
        self.assertEqual(v["silenceWords"]["verdict"], "same")
        self.assertEqual(v["loops"]["verdict"], "improved")
        self.assertEqual(v["rtf"]["verdict"], "regressed")
        self.assertEqual(v["peakMB"]["verdict"], "improved")
        self.assertEqual(v["termRecall"]["verdict"], "improved")
        self.assertEqual(v["deferredSegments"]["verdict"], "regressed")
        self.assertEqual(v["wer"]["delta"], -0.1)
        self.assertAlmostEqual(v["wer"]["pct"], -50.0)
        self.assertEqual(v["wer"]["delta"] < 0, True)

    def test_zero_baseline_and_missing(self):
        v = self.verdicts(self.rec(loops=0), self.rec(loops=3))
        self.assertIsNone(v["loops"]["pct"])
        self.assertEqual(v["loops"]["verdict"], "regressed")
        self.assertEqual(v["wer"]["verdict"], "n/a")

    def test_missing_recordings_listed(self):
        cmp = score.compare_runs({"recordings": {"a": self.rec(), "b": self.rec()}},
                                 {"recordings": {"b": self.rec(), "c": self.rec()}})
        self.assertEqual(cmp["onlyInBaseline"], ["a"])
        self.assertEqual(cmp["onlyInCandidate"], ["c"])
        text = score.render_compare(cmp)
        self.assertIn("a: only in baseline", text)
        self.assertIn("c: only in candidate", text)

    def test_cli_compare(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for name, wer in (("b.json", 0.2), ("c.json", 0.1)):
                p = os.path.join(tmp, name)
                with open(p, "w") as f:
                    json.dump({"recordings": {"r": self.rec(wer=wer)}}, f)
                paths.append(p)
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = score.main(["compare", "--baseline", paths[0], "--candidate", paths[1]])
            self.assertEqual(rc, 0)
            self.assertIn("improved", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
