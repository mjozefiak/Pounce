#!/usr/bin/env python3
"""Local judge panel for semantic note matching (MEET-1.4, part 2).

Standard library only. Run as: python3 -I judge_panel.py score --gold E --notes N --judges CONFIG [--out F]
Never prints note, transcript or name text: only meeting ids, judge names, families and numbers.

A match between a gold point and a note point that needs a semantic judgement is decided by a panel of 2-3
judges from different model families (criterion 2 of MEET-1.4):
  - every judge votes once on a candidate pair (lexical similarity >= CANDIDATE_FLOOR; below it nobody is asked);
  - unanimous: decided, not disputed;
  - not unanimous: disputed. Every judge votes again until it has `repeats` votes (>= MIN_REPEATS, default 5);
    the pair matches when more than half of ALL votes say yes;
  - the report gives, for the disputed pairs, the spread between repeats (standard deviation of the per-repeat
    share of judges saying yes), so a reader sees how stable the panel was.
The panel plugs into `score_notes` through its `similarity` seam. Before ANY call to a judge the meeting goes
through `score_notes.require_local_judge`: a non-local judge needs consent in the gold entry (criterion 4).
The judge protocol and prompt live in notes-rubric.md (section 6, between MATCH-PROMPT-BEGIN and END).
"""

import argparse
import json
import math
import os
import re
import subprocess
import sys

# `python3 -I` leaves the script's folder out of sys.path; put back only this folder, never the working directory.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import score_notes  # noqa: E402

SCHEMA = 1
MIN_REPEATS = 5
MIN_JUDGES, MAX_JUDGES = 2, 3
CANDIDATE_FLOOR = 0.15
JUDGES_ENV = "LINTEL_MEETING_EVAL_JUDGES"
RUBRIC_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "notes-rubric.md")
PROMPT_BEGIN, PROMPT_END = "<!-- MATCH-PROMPT-BEGIN -->", "<!-- MATCH-PROMPT-END -->"


class JudgeError(Exception):
    """A judge failed or answered outside the protocol. Never carries text from the meeting."""


class PanelError(Exception):
    """The panel is not a valid panel (size, families, repeats)."""


# ---------------------------------------------------------------- judges


class Judge:
    """One judge. Subclasses implement vote(); `family` is the model family, `is_local` is declared."""

    def __init__(self, name, family, is_local):
        self.name, self.family, self.is_local = name, family, is_local

    def vote(self, gold_text, note_text, repeat):
        raise NotImplementedError


def load_match_prompt(path=RUBRIC_PATH):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    try:
        body = text.split(PROMPT_BEGIN, 1)[1].split(PROMPT_END, 1)[0]
    except IndexError:
        raise PanelError("notes-rubric.md: match prompt markers missing")
    body = body.strip()
    if body.startswith("````text") or body.startswith("```text"):
        body = body.split("\n", 1)[1]
    return body.rsplit("```", 1)[0].strip()


def parse_vote(output):
    """The protocol answer is one JSON object {"match": true|false}."""
    try:
        data = json.loads(output.strip())
    except ValueError:
        raise JudgeError("answer is not JSON")
    if not isinstance(data, dict) or set(data) != {"match"} or not isinstance(data["match"], bool):
        raise JudgeError("answer breaks the protocol")
    return data["match"]


class CommandJudge(Judge):
    """A judge that is a local command: the prompt goes to stdin, the answer comes from stdout.
    The command is started without a shell. Whether it really stays on this Mac is the operator's
    declaration in the config (`local`); the tool cannot verify it."""

    def __init__(self, name, family, is_local, argv, prompt, timeout=300):
        super().__init__(name, family, is_local)
        self.argv, self.prompt, self.timeout = list(argv), prompt, timeout

    def vote(self, gold_text, note_text, repeat):
        values = {"{{GOLD}}": gold_text, "{{NOTE}}": note_text}
        prompt = re.sub(r"\{\{(GOLD|NOTE)\}\}", lambda m: values[m.group(0)], self.prompt)  # one pass
        for _ in range(2):  # one retry in a fresh process, like the whole-note protocol
            try:
                done = subprocess.run(self.argv, input=prompt, capture_output=True, text=True,
                                      timeout=self.timeout, check=True)
                return parse_vote(done.stdout)
            except (JudgeError, subprocess.SubprocessError, OSError):
                continue
        raise JudgeError("judge %s failed twice" % self.name)


def judges_from_config(config, prompt):
    """config: {"repeats": 5, "candidate_floor"?: 0.15, "judges": [{"name", "family", "local": bool, "argv": [...],
    "timeout"?: seconds}]}. Returns (judges, repeats, candidate_floor)."""
    if not isinstance(config, dict) or not isinstance(config.get("judges"), list):
        raise PanelError("judges config: judges missing")
    floor = config.get("candidate_floor", CANDIDATE_FLOOR)
    if isinstance(floor, bool) or not isinstance(floor, (int, float)) or not 0 <= floor <= 1:
        raise PanelError("judges config: candidate_floor must be a number in 0..1")
    out = []
    for i, j in enumerate(config["judges"]):
        if not isinstance(j, dict) or not all(isinstance(j.get(k), str) and j[k] for k in ("name", "family")):
            raise PanelError("judges[%d]: name and family required" % i)
        if not isinstance(j.get("local"), bool) or not isinstance(j.get("argv"), list) or not j["argv"]:
            raise PanelError("judges[%d]: local (bool) and argv required" % i)
        if not all(isinstance(a, str) and a for a in j["argv"]):
            raise PanelError("judges[%d]: argv must be non-empty strings" % i)
        timeout = j.get("timeout", 300)
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or timeout <= 0:
            raise PanelError("judges[%d]: timeout must be a positive number of seconds" % i)
        out.append(CommandJudge(j["name"], j["family"], j["local"], j["argv"], prompt, timeout))
    return out, config.get("repeats", MIN_REPEATS), floor


# ---------------------------------------------------------------- panel


def _std(xs):
    if len(xs) < 2:
        return 0.0
    m = sum(xs) / len(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


class Panel:
    def __init__(self, gold, judges, repeats=MIN_REPEATS, floor=CANDIDATE_FLOOR):
        if not MIN_JUDGES <= len(judges) <= MAX_JUDGES:
            raise PanelError("the panel needs %d to %d judges" % (MIN_JUDGES, MAX_JUDGES))
        if len({j.family.strip().lower() for j in judges}) != len(judges):
            raise PanelError("the judges must come from different model families")
        if len({j.name for j in judges}) != len(judges):
            raise PanelError("judge names must be unique")
        if not isinstance(repeats, int) or repeats < MIN_REPEATS:
            raise PanelError("disputed decisions need at least %d repeats" % MIN_REPEATS)
        for j in judges:  # before any call: refuses a non-local judge without consent
            score_notes.require_local_judge(gold, j.is_local)
        self.gold, self.judges, self.repeats, self.floor = gold, list(judges), repeats, floor
        self._cache = {}
        self.calls = 0

    def _ask(self, judge, g, n, repeat):
        score_notes.require_local_judge(self.gold, judge.is_local)
        self.calls += 1
        return bool(judge.vote(g, n, repeat))

    def decide(self, g, n):
        """Returns {"share": yes share over all votes, "disputed": bool, "spread": float|None, "asked": bool}."""
        key = (g, n)
        if key in self._cache:
            return self._cache[key]
        if score_notes.lexical_similarity(g, n) < self.floor:
            res = {"share": 0.0, "disputed": False, "spread": None, "asked": False}
        else:
            rounds = [[self._ask(j, g, n, 0) for j in self.judges]]
            if len({v for v in rounds[0]}) > 1:
                for r in range(1, self.repeats):
                    rounds.append([self._ask(j, g, n, r) for j in self.judges])
                shares = [sum(rd) / len(rd) for rd in rounds]
                res = {"share": sum(sum(rd) for rd in rounds) / (len(rounds) * len(self.judges)),
                       "disputed": True, "spread": _std(shares), "asked": True}
            else:
                res = {"share": 1.0 if rounds[0][0] else 0.0, "disputed": False, "spread": None, "asked": True}
        self._cache[key] = res
        return res

    def similarity(self, g, n):
        """The matcher for score_notes: the yes share when more than half of the votes say yes, else 0."""
        share = self.decide(g, n)["share"]
        return share if share > 0.5 else 0.0

    def report(self):
        asked = [d for d in self._cache.values() if d["asked"]]
        disputed = [d for d in asked if d["disputed"]]
        spreads = [d["spread"] for d in disputed]
        return {
            "protocol": SCHEMA,
            "judges": [{"name": j.name, "family": j.family, "local": j.is_local} for j in self.judges],
            "repeats": self.repeats,
            "candidateFloor": self.floor,
            "decisions": len(asked),
            "disputed": len(disputed),
            "judgeCalls": self.calls,
            "spread": {"mean": (sum(spreads) / len(spreads)) if spreads else 0.0,
                       "max": max(spreads) if spreads else 0.0},
        }


def score_with_panel(gold, notes, panel):
    scored = score_notes.score_notes(gold, notes, similarity=panel.similarity)
    scored["judgePanel"] = panel.report()
    return scored


# ---------------------------------------------------------------- output


def render(scored):
    jp = scored["judgePanel"]
    out = [score_notes.render_score(scored).rstrip("\n"),
           "  judges               %s" % ", ".join("%s (%s)" % (j["name"], j["family"]) for j in jp["judges"]),
           "  decisions            %d asked, %d disputed (x%d repeats), %d judge calls" % (
               jp["decisions"], jp["disputed"], jp["repeats"], jp["judgeCalls"]),
           "  spread between repeats  mean %.3f  max %.3f" % (jp["spread"]["mean"], jp["spread"]["max"])]
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(prog="judge_panel.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("score")
    s.add_argument("--gold", required=True)
    s.add_argument("--notes", required=True)
    s.add_argument("--judges", help="judges config JSON (default: $%s)" % JUDGES_ENV)
    s.add_argument("--out")
    args = ap.parse_args(argv)
    cfg_path = args.judges or os.environ.get(JUDGES_ENV)
    if not cfg_path:
        sys.stderr.write("judge_panel.py: no judges config (--judges or $%s)\n" % JUDGES_ENV)
        return 2
    try:
        gold, notes = score_notes._load(args.gold), score_notes._load(args.notes)
        judges, repeats, floor = judges_from_config(score_notes._load(cfg_path), load_match_prompt())
        scored = score_with_panel(gold, notes, Panel(gold, judges, repeats, floor))
        sys.stdout.write(render(scored))
        if args.out:
            with open(args.out, "w", encoding="utf-8") as f:
                json.dump(scored, f, ensure_ascii=False, indent=2)
        return 0
    except score_notes.ConsentError as e:
        sys.stderr.write("judge_panel.py: refused: %s\n" % e)  # names the meeting id only
        return 3
    except (score_notes.NotesError, PanelError, JudgeError, OSError, ValueError, KeyError) as e:
        sys.stderr.write("judge_panel.py: %s\n" % type(e).__name__)
        return 2


if __name__ == "__main__":
    sys.exit(main())
