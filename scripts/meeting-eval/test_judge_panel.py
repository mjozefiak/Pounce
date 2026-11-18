import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

import judge_panel as jp
import score_notes as sn

# Synthetic data only. Hand-computed expectations are in the comments.
G, N = "wybieramy bazę sqlite", "zdecydowaliśmy o sqlite"  # Dice 2*1/(3+3) = 0.33 >= floor 0.15, asked


class Scripted(jp.Judge):
    """A judge without a model: vote = script(repeat)."""

    def __init__(self, name, family, script, local=True):
        super().__init__(name, family, local)
        self.script, self.seen = script, []

    def vote(self, g, n, repeat):
        self.seen.append(repeat)
        return self.script(repeat)


def yes(_):
    return True


def no(_):
    return False


GOLD = {"id": "syn-1", "transcript": [], "key_points": [{"id": "k1", "text": G}], "decisions": [], "tasks": [],
        "consent": {"participants_agreed": True, "cloud_judges": False}}


class PanelTests(unittest.TestCase):
    def test_unanimous_is_one_round(self):
        a, b = Scripted("a", "qwen", yes), Scripted("b", "llama", yes)
        p = jp.Panel(GOLD, [a, b])
        d = p.decide(G, N)
        self.assertEqual((d["share"], d["disputed"], p.calls), (1.0, False, 2))
        self.assertEqual(a.seen, [0])

    def test_disputed_repeats_five_times_and_even_split_does_not_match(self):
        a, b = Scripted("a", "qwen", yes), Scripted("b", "llama", no)
        p = jp.Panel(GOLD, [a, b])
        d = p.decide(G, N)
        # every repeat is 1/2 yes: share 0.5 (not more than half), spread 0, 5 repeats x 2 judges
        self.assertEqual((d["share"], d["disputed"], d["spread"], p.calls), (0.5, True, 0.0, 10))
        self.assertEqual(a.seen, [0, 1, 2, 3, 4])
        self.assertEqual(p.similarity(G, N), 0.0)

    def test_three_judges_spread_between_repeats(self):
        c = Scripted("c", "gemma", lambda r: r % 2 == 1)  # no, yes, no, yes, no
        p = jp.Panel(GOLD, [Scripted("a", "qwen", yes), Scripted("b", "llama", yes), c])
        d = p.decide(G, N)
        # per-repeat yes shares 2/3, 1, 2/3, 1, 2/3: mean 0.8, sample std sqrt(0.13333/4) = 0.18257
        self.assertAlmostEqual(d["share"], 12 / 15)
        self.assertAlmostEqual(d["spread"], 0.18257, places=5)
        self.assertAlmostEqual(p.similarity(G, N), 0.8)
        self.assertEqual(p.calls, 15)

    def test_decisions_are_cached(self):
        p = jp.Panel(GOLD, [Scripted("a", "qwen", yes), Scripted("b", "llama", yes)])
        p.decide(G, N)
        p.decide(G, N)
        self.assertEqual(p.calls, 2)

    def test_unrelated_pair_asks_nobody(self):
        p = jp.Panel(GOLD, [Scripted("a", "qwen", yes), Scripted("b", "llama", yes)])
        self.assertEqual(p.similarity("alfa beta", "gamma delta"), 0.0)
        self.assertEqual(p.calls, 0)

    def test_panel_shape_is_validated(self):
        j = lambda n, f: Scripted(n, f, yes)
        with self.assertRaises(jp.PanelError):
            jp.Panel(GOLD, [j("a", "qwen")])
        with self.assertRaises(jp.PanelError):
            jp.Panel(GOLD, [j("a", "qwen"), j("b", "llama"), j("c", "gemma"), j("d", "phi")])
        with self.assertRaises(jp.PanelError):
            jp.Panel(GOLD, [j("a", "Qwen"), j("b", "qwen ")])  # same family
        with self.assertRaises(jp.PanelError):
            jp.Panel(GOLD, [j("a", "qwen"), j("b", "llama")], repeats=4)

    def test_report_has_counts_and_no_text(self):
        p = jp.Panel(GOLD, [Scripted("a", "qwen", yes), Scripted("b", "llama", no)])
        p.decide(G, N)
        r = p.report()
        self.assertEqual((r["decisions"], r["disputed"], r["judgeCalls"], r["repeats"]), (1, 1, 10, 5))
        self.assertNotIn("sqlite", json.dumps(r))


class ConsentTests(unittest.TestCase):
    def test_cloud_judge_refused_before_any_call(self):
        cloud = Scripted("c", "claude", yes, local=False)
        with self.assertRaises(sn.ConsentError):
            jp.Panel(GOLD, [Scripted("a", "qwen", yes), cloud])
        self.assertEqual(cloud.seen, [])

    def test_cloud_judge_allowed_with_consent(self):
        gold = dict(GOLD, consent={"participants_agreed": True, "cloud_judges": True})
        cloud = Scripted("c", "claude", yes, local=False)
        p = jp.Panel(gold, [Scripted("a", "qwen", yes), cloud])
        self.assertEqual(p.decide(G, N)["share"], 1.0)

    def test_consent_without_cloud_flag_is_not_enough(self):
        gold = dict(GOLD, consent={"participants_agreed": True, "cloud_judges": False})
        with self.assertRaises(sn.ConsentError):
            jp.Panel(gold, [Scripted("a", "qwen", yes), Scripted("c", "claude", yes, local=False)])


class ScoringTests(unittest.TestCase):
    NOTES = {"schema": 1, "meeting": "syn-1",
             "points": [{"kind": "decision", "text": N, "owner": None, "due": None, "quote": None}]}

    def test_panel_changes_coverage_over_lexical(self):
        lexical = sn.score_notes(GOLD, self.NOTES)
        self.assertEqual(lexical["coverage"]["num"], 0)  # Dice 0.33 < 0.5
        p = jp.Panel(GOLD, [Scripted("a", "qwen", yes), Scripted("b", "llama", yes)])
        scored = jp.score_with_panel(GOLD, self.NOTES, p)
        self.assertEqual((scored["coverage"]["num"], scored["coverage"]["den"]), (1, 1))
        self.assertEqual(scored["judgePanel"]["decisions"], 1)

    def test_panel_no_votes_no_coverage(self):
        p = jp.Panel(GOLD, [Scripted("a", "qwen", no), Scripted("b", "llama", no)])
        self.assertEqual(jp.score_with_panel(GOLD, self.NOTES, p)["coverage"]["num"], 0)

    def test_repeatability_with_scripted_judge(self):
        def run():
            p = jp.Panel(GOLD, [Scripted("a", "qwen", yes), Scripted("b", "llama", lambda r: r != 2)])
            return jp.score_with_panel(GOLD, self.NOTES, p)
        self.assertEqual(run(), run())


class ProtocolTests(unittest.TestCase):
    def test_parse_vote(self):
        self.assertTrue(jp.parse_vote(' {"match": true}\n'))
        self.assertFalse(jp.parse_vote('{"match": false}'))
        for bad in ("yes", '{"match": "true"}', '{"match": true, "x": 1}', "[true]", ""):
            with self.assertRaises(jp.JudgeError):
                jp.parse_vote(bad)

    def test_prompt_is_loaded_from_the_rubric(self):
        prompt = jp.load_match_prompt()
        self.assertIn("{{GOLD}}", prompt)
        self.assertIn("{{NOTE}}", prompt)
        with open(jp.RUBRIC_PATH, encoding="utf-8") as f:
            self.assertIn("rubric_version: 1", f.read())  # sections 1-5 are untouched

    def test_command_judge_and_one_retry(self):
        ok = jp.CommandJudge("a", "qwen", True, [sys.executable, "-c", 'print(\'{"match": true}\')'], "p")
        self.assertTrue(ok.vote("g", "n", 0))
        bad = jp.CommandJudge("b", "llama", True, [sys.executable, "-c", "print('maybe')"], "p")
        with self.assertRaises(jp.JudgeError) as cm:
            bad.vote("secret gold", "secret note", 0)
        self.assertNotIn("secret", str(cm.exception))

    def test_command_judge_substitutes_in_one_pass(self):
        script = "import sys,json; t=sys.stdin.read(); print(json.dumps({'match': t=='G={{NOTE}} N=n'}))"
        j = jp.CommandJudge("a", "qwen", True, [sys.executable, "-c", script], "G={{GOLD}} N={{NOTE}}")
        self.assertTrue(j.vote("{{NOTE}}", "n", 0))  # a placeholder inside the data is not expanded again

    def test_config_validation(self):
        with self.assertRaises(jp.PanelError):
            jp.judges_from_config({"judges": [{"name": "a"}]}, "p")
        with self.assertRaises(jp.PanelError):
            jp.judges_from_config({}, "p")
        base = {"name": "a", "family": "qwen", "local": True, "argv": ["x"]}
        for bad in ("300", -1, 0, True):  # timeout must be a positive number, not a crash in subprocess
            with self.assertRaises(jp.PanelError):
                jp.judges_from_config({"judges": [dict(base, timeout=bad)]}, "p")
        with self.assertRaises(jp.PanelError):
            jp.judges_from_config({"judges": [dict(base, argv=["x", 1])]}, "p")
        for bad in (-0.1, 1.5, "0.2", None):
            with self.assertRaises(jp.PanelError):
                jp.judges_from_config({"candidate_floor": bad, "judges": [base]}, "p")
        judges, repeats, floor = jp.judges_from_config({"judges": [dict(base, timeout=12.5)]}, "p")
        self.assertEqual((judges[0].timeout, repeats, floor), (12.5, 5, 0.15))

    def test_candidate_floor_zero_asks_every_pair(self):
        # "alfa beta" vs "gamma delta": Dice 0, skipped at the default floor, asked at floor 0.
        p = jp.Panel(GOLD, [Scripted("a", "qwen", yes), Scripted("b", "llama", yes)], floor=0)
        self.assertEqual(p.similarity("alfa beta", "gamma delta"), 1.0)
        self.assertEqual((p.calls, p.report()["candidateFloor"]), (2, 0))


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def write(self, name, obj):
        path = os.path.join(self.tmp.name, name)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(obj, f)
        return path

    def run_cli(self, gold, judges):
        notes = {"schema": 1, "meeting": "syn-1",
                 "points": [{"kind": "decision", "text": N, "owner": None, "due": None, "quote": None}]}
        argv = ["score", "--gold", self.write("g.json", gold), "--notes", self.write("n.json", notes),
                "--judges", self.write("j.json", judges)]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = jp.main(argv)
        return code, out.getvalue(), err.getvalue()

    def judge(self, name, family, local=True, answer="true"):
        return {"name": name, "family": family, "local": local,
                "argv": [sys.executable, "-c", 'print(\'{"match": %s}\')' % answer]}

    def test_scores_and_prints_no_text(self):
        code, out, err = self.run_cli(GOLD, {"judges": [self.judge("a", "qwen"), self.judge("b", "llama")]})
        self.assertEqual(code, 0, err)
        self.assertIn("coverage", out)
        self.assertIn("100.0% (1/1)", out)
        self.assertNotIn("sqlite", out + err)

    def test_cloud_judge_without_consent_exits_3_and_calls_nobody(self):
        marker = os.path.join(self.tmp.name, "called")
        cloud = {"name": "c", "family": "claude", "local": False,
                 "argv": [sys.executable, "-c", "open(%r,'w').close()" % marker]}
        code, out, err = self.run_cli(GOLD, {"judges": [self.judge("a", "qwen"), cloud]})
        self.assertEqual(code, 3)
        self.assertFalse(os.path.exists(marker))
        self.assertIn("syn-1", err)
        self.assertNotIn("sqlite", out + err)

    def test_isolated_mode_cli_starts_from_another_folder(self):
        # `python3 -I` (as documented) drops the script folder from sys.path; both tools must still import.
        import subprocess
        here = os.path.dirname(os.path.abspath(jp.__file__))
        for tool in ("judge_panel.py", "score_notes.py"):
            done = subprocess.run([sys.executable, "-I", os.path.join(here, tool), "--help"], cwd=self.tmp.name,
                                  capture_output=True, text=True, timeout=60)
            self.assertEqual(done.returncode, 0, tool + ": " + done.stderr[-300:])
        cfg = self.write("j.json", {"judges": [self.judge("a", "qwen"), self.judge("b", "llama")]})
        notes = self.write("n.json", {"schema": 1, "meeting": "syn-1", "points": [
            {"kind": "decision", "text": N, "owner": None, "due": None, "quote": None}]})
        done = subprocess.run([sys.executable, "-I", os.path.join(here, "judge_panel.py"), "score", "--gold",
                               self.write("g.json", GOLD), "--notes", notes, "--judges", cfg],
                              cwd=self.tmp.name, capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr[-300:])
        self.assertIn("100.0% (1/1)", done.stdout)

    def test_missing_config_exits_2(self):
        with contextlib.redirect_stderr(io.StringIO()), mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop(jp.JUDGES_ENV, None)
            self.assertEqual(jp.main(["score", "--gold", "x", "--notes", "y"]), 2)


@unittest.skipUnless(os.environ.get(jp.JUDGES_ENV), "real local judges: set %s to a judges config" % jp.JUDGES_ENV)
class RealJudgeTests(unittest.TestCase):
    """Off by default. Synthetic sentences only; needs the local models named in the config."""

    def test_identical_matches_and_different_does_not(self):
        with open(os.environ[jp.JUDGES_ENV], encoding="utf-8") as f:
            judges, repeats, floor = jp.judges_from_config(json.load(f), jp.load_match_prompt())
        p = jp.Panel(GOLD, judges, repeats, floor)
        self.assertGreater(p.similarity("Anna przygotuje raport kwartalny do piątku", "Anna przygotuje raport kwartalny do piątku"), 0.5)
        self.assertEqual(p.similarity("Anna przygotuje raport kwartalny do piątku", "Budżet na marketing wynosi dwa tysiące złotych"), 0.0)


if __name__ == "__main__":
    unittest.main()
