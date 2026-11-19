import json
import os
import stat
import tempfile
import time
import unittest

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


class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

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

    def test_end_to_end_with_fake_cli_leaks_no_marker_into_report(self):
        body = ('if [ "$1" = "--version" ]; then echo "9.9.9 (Claude Code)"; exit 0; fi\n'
                'if [ "$1" = "auth" ]; then echo \'{"loggedIn":true,"authMethod":"x","email":"a@b.c"}\'; exit 0; fi\n'
                'in=$(cat); echo "$in" > "$TMPDIR/copy-$$.txt"\n'
                'echo \'{"type":"result","result":"CODE: none","is_error":false,"usage":{"input_tokens":7,"output_tokens":3}}\'\n')
        path = fake_claude(self.dir, body)
        out = os.path.join(self.dir, "report.json")
        rc = canary.main(["--claude", path, "--out", out, "--medium-tokens", "100", "--large-tokens", "200",
                          "--cancel-after", "0.2", "--no-cleanup-control"])
        self.assertEqual(rc, 0)
        report = json.load(open(out))
        self.assertNotIn("a@b.c", json.dumps(report))
        self.assertEqual(report["cli"]["version"], "9.9.9")
        self.assertIn("coldTiny", report["checks"])
        # the fake CLI writes its stdin to TMPDIR, which is in the child's private temp: the scan must see it
        self.assertTrue(report["checks"]["diskCopies"]["callsWithAnyCopy"])


if __name__ == "__main__":
    unittest.main()
