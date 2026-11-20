import contextlib
import io
import json
import os
import shutil
import stat
import tempfile
import time
import subprocess
import unittest
from unittest import mock

import canary


def fake_claude(directory, body):
    path = os.path.join(directory, "claude")
    with open(path, "w") as f:
        f.write("#!/bin/sh\n" + body)
    os.chmod(path, 0o755)
    return path


class PureTests(unittest.TestCase):
    def test_redact_removes_email_token_and_home(self):
        line = canary.redact("Error for a.b@example.com sk-ant-abcdef123456 in %s/x" % os.path.expanduser("~"))
        self.assertNotIn("@", line)
        self.assertNotIn("sk-ant", line)
        self.assertIn("~/x", line)

    def test_redact_first_line_and_limit(self):
        self.assertEqual(canary.redact("one\ntwo"), "one")
        self.assertEqual(len(canary.redact("word " * 100)), 160)
        self.assertEqual(canary.redact(None), "")

    def test_marker_is_unique_and_prefixed(self):
        a, b = canary.new_marker(), canary.new_marker()
        self.assertNotEqual(a, b)
        self.assertTrue(a.startswith("LCANARY-"))

    def test_transcript_size_marker_and_language(self):
        for lang in ("pl", "en"):
            text = canary.synthetic_transcript(3000, lang, "LCANARY-x")
            est = canary.estimate_tokens(text, lang)
            self.assertEqual(text.count("LCANARY-x"), 1)
            self.assertTrue(2700 <= est <= 3400, (lang, est))
            self.assertTrue(text.startswith("[00:00] "))

    def test_env_allowlist_drops_everything_else(self):
        source = {"HOME": "/h", "PATH": "/evil", "SECRET_X": "1", "CLAUDECODE": "1", "ANTHROPIC_API_KEY": "k",
                  "HTTPS_PROXY": "p", "LANG": "en_US.UTF-8"}
        env = canary.build_env(source, "/t")
        self.assertEqual(env["PATH"], canary.FIXED_PATH)
        self.assertEqual(env["TMPDIR"], "/t")
        self.assertNotIn("SECRET_X", env)
        self.assertNotIn("CLAUDECODE", env)
        self.assertEqual(env["ANTHROPIC_API_KEY"], "k")
        self.assertEqual(canary.dropped_env_names(source), ["CLAUDECODE"])

    def test_env_home_override_drops_config_dir(self):
        env = canary.build_env({"HOME": "/h", "CLAUDE_CONFIG_DIR": "/c"}, "/t", home="/empty")
        self.assertEqual(env["HOME"], "/empty")
        self.assertNotIn("CLAUDE_CONFIG_DIR", env)

    def test_isolation_flags_golden(self):
        args = canary.ISOLATION_FLAGS
        for flag in ("-p", "--tools", "--no-session-persistence", "--disable-slash-commands", "--strict-mcp-config",
                     "--setting-sources"):
            self.assertIn(flag, args)
        self.assertEqual(args[args.index("--output-format") + 1], "json")

    def test_parse_result_object_and_array(self):
        obj = {"type": "result", "result": "hi", "is_error": False, "usage": {"input_tokens": 5,
               "cache_read_input_tokens": 10, "output_tokens": 2}}
        s, text = canary.parse_result(json.dumps(obj))
        self.assertEqual((s["input_tokens_total"], s["output_tokens"], text), (15, 2, "hi"))
        s, text = canary.parse_result(json.dumps([{"type": "system"}, obj]))
        self.assertEqual(text, "hi")
        self.assertEqual(canary.parse_result("not json")[0], {"json": False})

    def test_classify(self):
        self.assertEqual(canary.classify(0, ""), "ok")
        self.assertEqual(canary.classify(1, "Invalid API key. Please run /login"), "notSignedIn")
        self.assertEqual(canary.classify(1, "error: unknown option '--x'"), "incompatibleVersion")
        self.assertEqual(canary.classify(1, "429 rate limit"), "rateLimited")
        self.assertEqual(canary.classify(1, "ECONNREFUSED"), "network")
        self.assertEqual(canary.classify(1, "boom"), "other")
        self.assertEqual(canary.classify(-15, "", signaled=True), "cancelled")


class IsolationArgvTests(unittest.TestCase):
    def test_product_argv_has_every_required_flag_with_empty_values(self):
        argv = canary.isolated_argv("/x/claude", "haiku", "SYS")
        self.assertEqual(canary.missing_isolation(argv), [])
        self.assertEqual(canary.forbidden_in_product(argv), [])
        for flag in ("--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands", "-p"):
            self.assertIn(flag, argv)
        self.assertEqual(argv[argv.index("--setting-sources") + 1], "")
        self.assertEqual(argv[argv.index("--tools") + 1], "")
        self.assertEqual(argv[argv.index("--output-format") + 1], "json")

    def test_each_missing_or_non_empty_flag_is_reported(self):
        base = canary.isolated_argv("/x/claude", "haiku", "SYS")
        for flag in ("--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands"):
            self.assertEqual(canary.missing_isolation([a for a in base if a != flag]), [flag])
        loaded = list(base)
        loaded[loaded.index("--setting-sources") + 1] = "user"
        self.assertEqual(canary.missing_isolation(loaded), ["--setting-sources (must be empty)"])
        self.assertEqual(canary.missing_isolation(["claude", "-p"])[:2], ["--tools", "--no-session-persistence"])
        self.assertEqual(canary.forbidden_in_product(base + ["--settings", "{}"]), ["--settings"])

    def test_require_isolated_refuses_before_any_process(self):
        with self.assertRaises(RuntimeError):
            canary.require_isolated(["claude", "-p", "--model", "haiku"])
        argv = canary.isolated_argv("/x/claude", "haiku", "SYS")
        self.assertIs(canary.require_isolated(argv), argv)

    def test_only_the_content_free_commands_may_skip_the_flags(self):
        self.assertEqual(canary.require_no_content(["--version"]), ["--version"])
        self.assertEqual(canary.require_no_content(("auth", "status")), ["auth", "status"])
        self.assertEqual(canary.require_no_content(["--help"]), ["--help"])
        for args in (["-p"], ["auth", "login"], ["--version", "-p"], ["auth", "status", "--settings", "{}"], []):
            with self.assertRaises(RuntimeError):
                canary.require_no_content(args)

    def test_unknown_step_in_only_is_refused_before_any_process(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, True)
        old_tmp, tempfile.tempdir = tempfile.tempdir, tmp
        try:
            with contextlib.redirect_stderr(io.StringIO()) as err:
                rc = canary.main(["--claude", "/bin/sh", "--only", "isolation,hookEvents"])
        finally:
            tempfile.tempdir = old_tmp
        self.assertEqual(rc, 2)
        self.assertIn("hookEvents", err.getvalue())
        self.assertEqual(os.listdir(tmp), [])  # no work directory, no call

    def test_positive_control_with_the_real_config_is_off_by_default(self):
        ap_default = self._parse([])
        self.assertFalse(ap_default)
        self.assertTrue(self._parse(["--positive-control-real-config", "--only", "realConfig"]))

    def _parse(self, extra):
        seen = {}

        class Stop(Exception):
            pass

        def fake_init(self_, args):
            seen["flag"] = args.positive_control_real_config
            raise Stop()

        original = canary.Canary.__init__
        canary.Canary.__init__ = fake_init
        try:
            with contextlib.redirect_stderr(io.StringIO()) as err:
                with self.assertRaises(Stop):
                    canary.main(["--claude", "/bin/sh"] + extra)
        finally:
            canary.Canary.__init__ = original
        self.assertEqual("REAL" in err.getvalue(), bool(seen["flag"]))  # the warning is printed only with the flag
        return seen["flag"]


class RealConfigControlTests(unittest.TestCase):
    def test_pair_argv_differs_only_in_the_configuration_flags(self):
        loose = canary.stream_argv("/x/claude", "haiku", "/d", False)
        iso = canary.stream_argv("/x/claude", "haiku", "/d", True)
        for argv in (loose, iso):
            self.assertIn("--no-session-persistence", argv)
            self.assertEqual(argv[argv.index("--tools") + 1], "")
            self.assertEqual(canary.forbidden_in_product(argv), [])
        self.assertEqual(canary.missing_isolation(iso), [])
        self.assertEqual(sorted(canary.missing_isolation(loose)), ["--disable-slash-commands", "--setting-sources",
                                                                    "--strict-mcp-config"])

    def test_snapshot_diff_lists_new_and_modified_names_and_never_opens_files(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        os.makedirs(os.path.join(d, "a"))
        with open(os.path.join(d, "a", "old.txt"), "w") as f:
            f.write("x")
        before = canary.snapshot_tree(d)
        os.makedirs(os.path.join(d, "b"))
        os.utime(os.path.join(d, "a", "old.txt"), (1, 1))
        with open(os.path.join(d, "b", "new.txt"), "w") as f:
            f.write("y")
        with mock.patch("builtins.open", side_effect=AssertionError("content must not be read")):
            after = canary.snapshot_tree(d)
        dirs, files, modified = canary.diff_snapshots(before, after)
        self.assertEqual((dirs, files, modified), (["b"], [os.path.join("b", "new.txt")], [os.path.join("a", "old.txt")]))

    def test_init_counts_keeps_numbers_only(self):
        ev = {"type": "system", "subtype": "init", "tools": [], "mcp_servers": [{"name": "private"}], "skills": ["s", "t"],
              "plugins": [{"name": "cc-plugin-x"}, {"name": "mine"}], "agents": ["a"], "slash_commands": []}
        out = canary.init_counts(json.dumps(ev))
        self.assertEqual((out["mcp_servers"], out["skills"], out["plugins"], out["pluginsNotBuiltIn"]), (1, 2, 2, 1))
        self.assertNotIn("private", json.dumps(out))
        self.assertIsNone(canary.init_counts("not json"))


class UserConfigTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)

    def test_build_user_config_stays_inside_home_and_names_its_markers(self):
        home, marks = os.path.join(self.dir, "home"), os.path.join(self.dir, "marks")
        os.makedirs(marks)
        names = canary.build_user_config(home, marks)
        self.assertEqual(set(names), {"hook-user-SessionStart", "hook-user-UserPromptSubmit", "hook-user-Stop",
                                      "hook-user-SessionEnd", "mcp-user", "plugin-hook"})
        with open(os.path.join(home, ".claude", "settings.json")) as f:
            settings = json.load(f)
        command = settings["hooks"]["SessionStart"][0]["hooks"][0]["command"]
        self.assertTrue(command.startswith("/usr/bin/touch " + marks))
        self.assertTrue(settings["enabledPlugins"]["canary-plugin@canary-market"])
        with open(os.path.join(home, ".claude.json")) as f:
            self.assertIn("canary-user", json.load(f)["mcpServers"])
        self.assertEqual(os.listdir(marks), [])  # building it runs nothing

    def test_temp_home_env_cannot_log_in_and_drops_the_real_config(self):
        c = canary.Canary.__new__(canary.Canary)
        c.child_tmp = self.dir
        old = dict(os.environ)
        os.environ.update({"ANTHROPIC_API_KEY": "k", "CLAUDE_CONFIG_DIR": "/real", "CLAUDE_CODE_OAUTH_TOKEN": "t"})
        try:
            env = c.temp_home_env("/tmp-home")
        finally:
            os.environ.clear()
            os.environ.update(old)
        self.assertEqual(env["HOME"], "/tmp-home")
        for name in ("ANTHROPIC_API_KEY", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN"):
            self.assertNotIn(name, env)

    def test_session_scan_returns_paths_only_for_jsonl_with_the_marker(self):
        proj = os.path.join(self.dir, "projects", "enc")
        os.makedirs(proj)
        for name, text in (("a.jsonl", "x LCANARY-aaa private words"), ("b.jsonl", "nothing"), ("c.txt", "LCANARY-aaa")):
            with open(os.path.join(proj, name), "w") as f:
                f.write(text)
        found = canary.session_files_with_marker(self.dir, "LCANARY-aaa")
        self.assertEqual(found, [os.path.join(proj, "a.jsonl")])
        self.assertEqual(canary.session_files_with_marker(os.path.join(self.dir, "missing"), "LCANARY-aaa"), [])

    def test_read_stream_counts_hooks_and_keeps_no_foreign_names(self):
        lines = [
            {"type": "system", "subtype": "init", "tools": [], "mcp_servers": [{"name": "private-server"}],
             "plugins": [{"name": "cc-plugin-privacy"}, {"name": "my-private-plugin"}], "agents": ["a"]},
            {"type": "system", "subtype": "hook_started", "hook_event": "Stop", "hook_name": "private hook name"},
            {"type": "system", "subtype": "hook_started", "hook_event": "Weird"},
            {"type": "result", "is_error": False, "result": "the answer"},
        ]
        out, answer = canary.read_stream("\n".join(json.dumps(x) for x in lines) + "\nnot json\n")
        self.assertEqual((out["mcpServers"], out["plugins"], out["pluginsNotBuiltIn"]), (1, 2, 1))
        self.assertEqual(out["hookEventsStarted"], {"Stop": 1, "other": 1})
        self.assertEqual(answer, "the answer")
        text = json.dumps(out)
        for private in ("private", "the answer"):
            self.assertNotIn(private, text)


FAKE_CLI = ('printf \'%s\\t%s\\n\' "$HOME" "$*" >> "$CANARY_TEST_ARGV_LOG"\n'
            'if [ "$1" = "--version" ]; then echo "9.9.9 (Claude Code)"; exit 0; fi\n'
            'if [ "$1" = "--help" ]; then echo "  --safe-mode   Start with all customizations disabled"; exit 0; fi\n'
            'if [ "$1" = "auth" ]; then echo \'{"loggedIn":true,"authMethod":"x","email":"a@b.c"}\'; exit 0; fi\n'
                        'in=$(cat); echo "$in" > "$TMPDIR/copy-$$.txt"\n'
            'case " $* " in *" --no-session-persistence "*) ;; *) mkdir -p "$HOME/.claude/projects/p"; '
            'echo "$in" > "$HOME/.claude/projects/p/$$.jsonl";; esac\n'
            'echo \'{"type":"result","result":"CODE: none","is_error":false,"usage":{"input_tokens":7,"output_tokens":3}}\'\n')


class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)

    def test_run_child_reports_numbers_not_text_in_public(self):
        path = fake_claude(self.dir, 'cat >/dev/null; echo out; echo err >&2; exit 3\n')
        r = canary.run_child([path], "in", {"PATH": canary.FIXED_PATH}, self.dir)
        self.assertEqual(r["exit"], 3)
        self.assertEqual(canary.public(r).keys() & {"_stdout", "_stderr"}, set())
        self.assertEqual(r["leftoverProcesses"], 0)

    def test_cancel_sends_sigterm_to_group(self):
        path = fake_claude(self.dir, "sleep 30 &\nsleep 30\n")
        t = time.monotonic()
        r = canary.run_child([path], "", {"PATH": canary.FIXED_PATH}, self.dir, cancel_after=0.3)
        self.assertLess(time.monotonic() - t, 5)
        self.assertTrue(r["cancelled"])
        self.assertEqual(r["leftoverProcesses"], 0)

    def test_interrupted_run_kills_the_child_group(self):
        pidfile = os.path.join(self.dir, "pid")
        path = fake_claude(self.dir, 'echo $$ > "%s"\nsleep 30 &\nsleep 30\n' % pidfile)
        real_sleep = time.sleep

        def interrupt(_seconds):
            deadline = time.monotonic() + 5
            while not os.path.exists(pidfile) and time.monotonic() < deadline:
                real_sleep(0.02)
            real_sleep(0.1)
            raise KeyboardInterrupt()

        t = time.monotonic()
        with mock.patch.object(canary.time, "sleep", interrupt):
            with self.assertRaises(KeyboardInterrupt):
                canary.run_child([path], "", {"PATH": canary.FIXED_PATH}, self.dir, cancel_after=10)
        self.assertLess(time.monotonic() - t, 8)
        with open(pidfile) as f:
            pgid = f.read().strip()
        left = subprocess.run(["/usr/bin/pgrep", "-g", pgid], capture_output=True, text=True).stdout.split()
        self.assertEqual(left, [])

    def test_scan_finds_marker_across_chunks_and_ignores_old_files(self):
        old = os.path.join(self.dir, "old.txt")
        new = os.path.join(self.dir, "new.txt")
        with open(old, "w") as f:
            f.write("LCANARY-aaa")
        os.utime(old, (1, 1))
        with open(new, "wb") as f:
            f.write(b"x" * (8 << 20) + b"LCANARY-aaa" + b"y")
        hits, counts = canary.scan_for_markers([self.dir], ["LCANARY-aaa", "LCANARY-bbb"], time.time() - 5)
        self.assertEqual(hits["LCANARY-aaa"], [new])
        self.assertEqual(hits["LCANARY-bbb"], [])
        self.assertEqual(counts["filesChangedSince"], 1)

    def run_main(self, extra):
        """Runs the whole canary against the fake CLI with a fake real HOME. Returns (report, argv lines, work dirs)."""
        path = fake_claude(self.dir, FAKE_CLI)
        out, log = os.path.join(self.dir, "report.json"), os.path.join(self.dir, "argv.log")
        home, tmp = os.path.join(self.dir, "real-home"), os.path.join(self.dir, "systmp")
        os.makedirs(home)
        os.makedirs(tmp)
        old, old_tmp, old_allow = dict(os.environ), tempfile.tempdir, list(canary.ENV_ALLOW)
        os.environ.update({"HOME": home, "TMPDIR": tmp, "CANARY_TEST_ARGV_LOG": log})
        os.environ.pop("CLAUDE_CONFIG_DIR", None)
        tempfile.tempdir = tmp
        canary.ENV_ALLOW.append("CANARY_TEST_ARGV_LOG")
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                rc = canary.main(["--claude", path, "--out", out, "--medium-tokens", "100", "--large-tokens", "200",
                                  "--cancel-after", "0.2"] + extra)
        finally:
            canary.ENV_ALLOW[:] = old_allow
            tempfile.tempdir = old_tmp
            os.environ.clear()
            os.environ.update(old)
        self.assertEqual(rc, 0)
        with open(out) as f:
            report = json.load(f)
        with open(log) as f:
            argv_lines = [tuple(line.split("\t", 1)) for line in f.read().splitlines()]
        return report, argv_lines, home, tmp

    def test_end_to_end_default_run_is_isolated_and_cleans_up(self):
        report, argv_lines, home, tmp = self.run_main([])
        text = json.dumps(report)
        self.assertNotIn("a@b.c", text)
        self.assertNotIn("LCANARY-", text)
        self.assertEqual(report["cli"]["version"], "9.9.9")
        self.assertIn("coldTiny", report["checks"])
        checks = report["checks"]
        # the positive control with the real configuration is skipped by default
        self.assertTrue(checks["realConfig"]["skipped"])
        self.assertNotIn("control", checks)
        self.assertNotIn("realConfigWithoutTheFlag", checks["hookEvents"])
        # --safe-mode is measured with the isolation flags only (the fake CLI has no init event: no difference seen)
        self.assertTrue(checks["safeMode"]["cliSupportsFlag"])
        self.assertFalse(checks["safeMode"]["recommendInGoldenList"])
        # the fake CLI writes its stdin to TMPDIR (private temp of the child): the scan must see it
        self.assertTrue(checks["diskCopies"]["callsWithAnyCopy"])
        # ... and a session file whenever --no-session-persistence is missing: only in the temporary HOME cases
        self.assertEqual(checks["userConfig"]["control"]["sessionFilesWithMarker"], 1)
        self.assertEqual(checks["userConfig"]["product"]["sessionFilesWithMarker"], 0)
        self.assertEqual(checks["userConfig"]["noSessionPersistenceOnly"]["sessionFilesWithMarker"], 0)
        self.assertTrue(checks["diskCopies"]["noSessionFileFromIsolatedCalls"])
        self.assertFalse(os.path.exists(os.path.join(home, ".claude")))  # nothing written to the "real" config
        # every call with the real HOME carries the isolation flags or is a command without content
        for call_home, args in argv_lines:
            if call_home == home and canary.missing_isolation(args.split(" ") + [""]):
                self.assertIn(args.split(" "), canary.NO_CONTENT_COMMANDS)
        # every model call without the flags is one of the five temporary-HOME cases
        loose = [(h, a) for h, a in argv_lines if "-p" in a.split(" ") and canary.missing_isolation(a.split(" ") + [""])]
        self.assertEqual(len(loose), 5, loose)
        self.assertTrue(all(h != home for h, _a in loose))
        # the work directory is removed
        self.assertEqual([n for n in os.listdir(tmp) if n.startswith("provider-canary-")], [])

    def test_end_to_end_opt_in_runs_one_pair_with_and_without_the_flags(self):
        report, argv_lines, home, tmp = self.run_main(["--positive-control-real-config", "--only", "realConfig"])
        rc = report["checks"]["realConfig"]
        self.assertNotIn("skipped", rc)
        calls = [a.split(" ") for h, a in argv_lines if h == home and "-p" in a.split(" ")]
        self.assertEqual(len(calls), 2)  # one pair, nothing else
        loose = [c for c in calls if canary.missing_isolation(c + [""])]
        self.assertEqual(len(loose), 1)
        for c in calls:  # no session file and no tool in either call
            self.assertIn("--no-session-persistence", c)
            self.assertEqual(c[c.index("--tools") + 1], "")
        self.assertEqual(set(rc["withFlags"]["counts"]), set(rc["withoutFlags"]["counts"]))
        self.assertEqual(rc["configDirChanges"]["counts"]["newFiles"], 0)  # the fake CLI writes nothing there
        self.assertNotIn("newFiles", json.dumps(rc["configDirChanges"]).replace('"newFiles": 0', ""))
        self.assertEqual([n for n in os.listdir(tmp) if n.startswith("provider-canary-")], [])

    def test_opt_in_is_refused_next_to_any_other_step(self):
        path = fake_claude(self.dir, FAKE_CLI)
        for only in ([], ["--only", "realConfig,disk"], ["--only", "disk"]):
            with mock.patch("sys.stderr"):
                self.assertEqual(canary.main(["--claude", path, "--positive-control-real-config"] + only), 2)

    def test_work_directory_is_removed_when_a_step_raises(self):
        path = fake_claude(self.dir, FAKE_CLI)
        tmp = os.path.join(self.dir, "systmp")
        os.makedirs(tmp)
        old_tmp, original = tempfile.tempdir, canary.Canary.env_allowlist
        tempfile.tempdir = tmp

        def boom(self_):
            raise ValueError("synthetic failure")

        canary.Canary.env_allowlist = boom
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(ValueError):
                    canary.main(["--claude", path, "--no-calls"])
        finally:
            canary.Canary.env_allowlist = original
            tempfile.tempdir = old_tmp
        self.assertEqual(os.listdir(tmp), [])


if __name__ == "__main__":
    unittest.main()
