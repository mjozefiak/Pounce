import contextlib
import io
import json
import os
import tempfile
import unittest

import score_notes as sn

# Synthetic data only. Hand-computed expectations are in the comments.
GOLD = {
    "id": "syn-1",
    "transcript": [
        {"speaker": "a", "start": 0, "end": 5, "text": "Uruchamiamy wersję testową w piątek, dobrze?"},
        {"speaker": "b", "start": 5, "end": 9, "text": "Anna przygotuje raport kwartalny do 1 grudnia."},
    ],
    "key_points": [
        {"id": "k1", "text": "uruchamiamy wersję testową w piątek"},
        {"id": "k2", "text": "budżet wynosi 2000 złotych"},
    ],
    "decisions": [{"id": "d1", "text": "wybieramy bazę sqlite"}],
    "tasks": [
        {"id": "t1", "text": "Anna przygotuje raport kwartalny", "owner": "Anna", "due": "2026-12-01"},
        {"id": "t2", "text": "Piotr wyśle ofertę klientowi", "owner": "Piotr", "due": None},
    ],
    "consent": {"participants_agreed": True, "cloud_judges": False},
}


def pt(kind, text, quote=None, owner=None, due=None):
    p = {"kind": kind, "text": text, "owner": owner, "due": due}
    p["quote"] = {"text": quote, "time": "00:01"} if quote else None
    return p


NOTES = {"schema": 1, "meeting": "syn-1", "points": [
    pt("key_point", "uruchamiamy wersję testową w piątek rano", quote="wersję testową w piątek"),
    pt("decision", "wybieramy bazę sqlite do projektu", quote="wybieramy bazę sqlite"),
    pt("summary", "krótkie podsumowanie bez dopasowania"),
    pt("question", "kto zrobi raport kwartalny"),
    pt("task", "Anna przygotuje raport kwartalny", quote="Anna przygotuje raport kwartalny", owner="anna", due="2026-12-01"),
    pt("task", "Piotr wyśle ofertę klientowi", owner="Marek"),
    pt("task", "zamówić pizzę"),
]}


class MatchingTests(unittest.TestCase):
    def test_dice_hand_computed(self):
        # 5 and 6 tokens, 5 shared: 2*5/11
        self.assertAlmostEqual(sn.lexical_similarity(
            "uruchamiamy wersję testową w piątek", "uruchamiamy wersję testową w piątek rano"), 10 / 11)

    def test_numbers_folded_like_wer(self):
        self.assertEqual(sn.lexical_similarity("dwa tysiące złotych", "2000 złotych"), 1.0)

    def test_one_to_one_best_first(self):
        # the single note text can match only one gold text: the better one
        pairs = sn.match_pairs(["a b c", "a b c d"], ["a b c d"], threshold=0.5)
        self.assertEqual(pairs, [(1, 0)])

    def test_custom_matcher_is_used(self):
        pairs = sn.match_pairs(["x"], ["y"], similarity=lambda g, n: 1.0)
        self.assertEqual(pairs, [(0, 0)])


class MetricTests(unittest.TestCase):
    def setUp(self):
        self.s = sn.score_notes(GOLD, NOTES)

    def test_coverage(self):
        # k1 and d1 matched (0.909, 0.75), k2 not: 2 of 3; question and summary never match
        self.assertEqual((self.s["coverage"]["num"], self.s["coverage"]["den"]), (2, 3))
        self.assertAlmostEqual(self.s["coverage"]["value"], 2 / 3)

    def test_question_never_covers(self):
        notes = {"schema": 1, "points": [pt("question", "uruchamiamy wersję testową w piątek")]}
        self.assertEqual(sn.coverage(GOLD, notes)["num"], 0)

    def test_quote_confirmed(self):
        # 6 non-question points; confirmed: the key point and the Anna task: 2 of 6
        q = self.s["quoteConfirmedShare"]
        self.assertEqual((q["num"], q["den"]), (2, 6))

    def test_quote_across_segments_is_not_confirmed(self):
        notes = {"schema": 1, "points": [pt("key_point", "x", quote="w piątek dobrze anna przygotuje")]}
        self.assertEqual(sn.quote_confirmed_share(GOLD, notes)["num"], 0)

    def test_quote_inside_one_segment_ignores_punctuation(self):
        notes = {"schema": 1, "points": [pt("key_point", "x", quote="W piątek, dobrze")]}
        self.assertEqual(sn.quote_confirmed_share(GOLD, notes)["num"], 1)

    def test_task_f1_levels(self):
        # 3 note tasks, 2 gold. task: tp 2 -> P 2/3, R 1, F1 0.8. owner: tp 1 -> P 1/3, R 1/2, F1 0.4.
        # due: Anna's due also equal -> tp 1, F1 0.4
        f = self.s["taskF1"]
        self.assertAlmostEqual(f["task"]["f1"], 0.8)
        self.assertAlmostEqual(f["owner"]["f1"], 0.4)
        self.assertAlmostEqual(f["due"]["f1"], 0.4)
        self.assertEqual((f["task"]["tp"], f["task"]["predicted"], f["task"]["actual"]), (2, 3, 2))

    def test_due_level_drops_wrong_due(self):
        notes = {"schema": 1, "points": [
            pt("task", "Anna przygotuje raport kwartalny", owner="Anna", due="2026-12-02")]}
        f = sn.task_f1(GOLD, notes)
        self.assertEqual((f["task"]["tp"], f["owner"]["tp"], f["due"]["tp"]), (1, 1, 0))

    def test_no_note_tasks_is_zero_not_error(self):
        f = sn.task_f1(GOLD, {"schema": 1, "points": []})
        self.assertEqual(f["task"]["f1"], 0.0)

    def test_empty_notes_all_zero(self):
        s = sn.score_notes(GOLD, {"schema": 1, "points": []})
        self.assertEqual((s["coverage"]["num"], s["quoteConfirmedShare"]["den"]), (0, 0))
        self.assertEqual(s["quoteConfirmedShare"]["value"], 0.0)

    def test_malformed_notes(self):
        with self.assertRaises(sn.NotesError):
            sn.score_notes(GOLD, {"schema": 2, "points": []})
        with self.assertRaises(sn.NotesError):
            sn.score_notes(GOLD, {"schema": 1, "points": [{"kind": "bogus", "text": "x"}]})

    def test_malformed_point_fields(self):
        for bad in ({"owner": 1}, {"due": 20261201}, {"quote": "plain text"}, {"quote": {"time": "00:01"}}):
            point = dict(pt("task", "x"), **bad)
            with self.assertRaises(sn.NotesError):
                sn.score_notes(GOLD, {"schema": 1, "points": [point]})

    def test_notes_of_another_meeting_refused(self):
        with self.assertRaises(sn.NotesError):
            sn.score_notes(GOLD, dict(NOTES, meeting="syn-2"))

    def test_notes_without_meeting_id_scored(self):
        notes = {k: v for k, v in NOTES.items() if k != "meeting"}
        self.assertEqual(sn.score_notes(GOLD, notes)["coverage"]["num"], 2)

    def test_deterministic(self):
        # same input, same output, byte for byte: no set or dict order leaks into the result
        first = json.dumps(sn.score_notes(GOLD, NOTES), sort_keys=True)
        for _ in range(20):
            self.assertEqual(json.dumps(sn.score_notes(GOLD, NOTES), sort_keys=True), first)

    def test_ties_broken_by_index(self):
        # two equal candidates: the lower note index wins, every time
        for _ in range(20):
            self.assertEqual(sn.match_pairs(["a b"], ["a b", "a b"]), [(0, 0)])

    def test_custom_matcher_changes_coverage(self):
        s = sn.score_notes(GOLD, NOTES, similarity=lambda g, n: 1.0)
        self.assertEqual(s["coverage"]["num"], 3)


class ConsentTests(unittest.TestCase):
    def test_local_judge_always_allowed(self):
        sn.require_local_judge({"id": "x"}, True)

    def test_cloud_judge_refused_without_consent(self):
        with self.assertRaises(sn.ConsentError):
            sn.require_local_judge(GOLD, False)  # cloud_judges false
        with self.assertRaises(sn.ConsentError):
            sn.require_local_judge({"id": "x"}, False)  # no consent object

    def test_cloud_judge_allowed_with_consent(self):
        g = dict(GOLD, consent={"participants_agreed": True, "cloud_judges": True})
        sn.require_local_judge(g, False)

    def test_cloud_flag_without_participants_agreed_refused(self):
        g = dict(GOLD, consent={"participants_agreed": False, "cloud_judges": True})
        with self.assertRaises(sn.ConsentError):
            sn.require_local_judge(g, False)

    def test_error_message_has_no_content(self):
        try:
            sn.require_local_judge(GOLD, False)
        except sn.ConsentError as e:
            self.assertEqual(str(e), "meeting syn-1 has no consent for non-local judges")


def run_of(values, meeting="m1"):
    return {meeting: {"coverage": {"value": values}}}


class CompareTests(unittest.TestCase):
    def runs(self, vals):
        return [run_of(v) for v in vals]

    def test_above_noise(self):
        # base [0.5, 0.6, 0.4]: mean 0.5, std 0.1; cand [0.7, 0.8, 0.6]: mean 0.7, std 0.1
        c = sn.compare_variants(self.runs([0.5, 0.6, 0.4]), self.runs([0.7, 0.8, 0.6]), "coverage")
        self.assertAlmostEqual(c["meanDifference"], 0.2)
        self.assertAlmostEqual(c["noise"], 0.1)
        self.assertEqual(c["verdict"], "above-noise")

    def test_within_noise(self):
        c = sn.compare_variants(self.runs([0.5, 0.6, 0.4]), self.runs([0.45, 0.65, 0.55]), "coverage")
        self.assertAlmostEqual(c["meanDifference"], 0.05)
        self.assertEqual(c["verdict"], "within-noise")

    def test_negative_difference_also_above_noise(self):
        c = sn.compare_variants(self.runs([0.7, 0.8, 0.6]), self.runs([0.5, 0.6, 0.4]), "coverage")
        self.assertEqual(c["verdict"], "above-noise")
        self.assertLess(c["meanDifference"], 0)

    def test_fewer_than_three_runs(self):
        c = sn.compare_variants(self.runs([0.5, 0.6]), self.runs([0.7, 0.8, 0.9]), "coverage")
        self.assertEqual(c["verdict"], "insufficient-runs")

    def test_pairs_only_shared_meetings(self):
        base = [dict(run_of(v), other=run_of(0.1)["m1"]) for v in (0.5, 0.6, 0.4)]
        cand = self.runs([0.7, 0.8, 0.6])
        self.assertEqual(sn.compare_variants(base, cand, "coverage")["meetings"], 1)

    def test_no_shared_meeting(self):
        with self.assertRaises(sn.NotesError):
            sn.compare_variants(self.runs([1, 1, 1]), [run_of(1, "zz")] * 3, "coverage")

    def test_metric_paths(self):
        s = sn.score_notes(GOLD, NOTES)
        self.assertAlmostEqual(sn.metric_value(s, "taskF1.owner"), 0.4)
        self.assertAlmostEqual(sn.metric_value(s, "quoteConfirmedShare"), 2 / 6)
        with self.assertRaises(sn.NotesError):
            sn.metric_value(s, "nope")


class CliTests(unittest.TestCase):
    def test_score_output_has_numbers_not_text(self):
        with tempfile.TemporaryDirectory() as d:
            gp, np_ = os.path.join(d, "g.json"), os.path.join(d, "n.json")
            for p, o in ((gp, GOLD), (np_, NOTES)):
                with open(p, "w", encoding="utf-8") as f:
                    json.dump(o, f)
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = sn.main(["score", "--gold", gp, "--notes", np_])
        out = buf.getvalue()
        self.assertEqual(rc, 0)
        self.assertIn("coverage", out)
        self.assertIn("66.7% (2/3)", out)
        self.assertNotIn("sqlite", out)
        self.assertNotIn("Anna", out)

    def test_bad_input_exit_2(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = sn.main(["score", "--gold", "/nonexistent.json", "--notes", "/nonexistent.json"])
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main()
