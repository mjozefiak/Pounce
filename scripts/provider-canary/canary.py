#!/usr/bin/env python3
"""Manual isolation and timing canary for the Claude Code CLI as a notes provider.

Spec: .ai/specs/2026-11-10-external-ai-providers.md, section "Kanarek izolacji" and steps 0.1, 0.2.
NOT part of the build, the tests of the app or CI. Nothing in the app calls it.

The default run never loads the user's own hooks, settings, MCP servers or plugins: every call made with the real
login passes the isolation flags (checked by `require_isolated` before the process starts), and every call made
without them runs in a temporary HOME built here, where the CLI is not logged in. Calls that load the user's real
configuration exist only behind `--positive-control-real-config` (off by default; see the README).

Every byte sent to the CLI is synthetic text generated here, with a random canary marker per call. The report holds
numbers, flag names, exit codes, paths and counts. It never holds the markers, prompts, answers or stderr text
(failure output is classified and cut to a redacted first line). Python 3 standard library only; run with `python3 -I`.
"""
import argparse
import json
import os
import random
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

# Flags the descriptor of the app is expected to use (spec, "API Contracts"). The only place argv is built here.
ISOLATION_FLAGS = [
    "-p", "--output-format", "json", "--tools", "", "--no-session-persistence", "--disable-slash-commands",
    "--strict-mcp-config", "--setting-sources",
]
# Each of these must be in the argv of every call that runs with the user's real HOME (the product's requirement).
REQUIRED_WITH_REAL_CONFIG = ["-p", "--tools", "--no-session-persistence", "--disable-slash-commands",
                             "--strict-mcp-config", "--setting-sources"]
# Flags that would bring configuration back in; the product argv must never hold them.
FORBIDDEN_IN_PRODUCT = ["--settings", "--mcp-config", "--plugin-dir", "--plugin-url", "--add-dir", "--agents",
                        "--append-system-prompt", "--continue", "-c", "--resume", "-r", "--dangerously-skip-permissions"]
USER_HOOK_EVENTS = ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"]
FIXED_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
ENV_ALLOW = ["HOME", "USER", "LANG", "TMPDIR", "CLAUDE_CONFIG_DIR"]  # USER: the Keychain login is found by it
PROXY_VARS = ["HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "no_proxy", "all_proxy"]
AUTH_VARS = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL",
             "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]
# Estimator of the app (NotesText.estimateTokens, ADR 0004): words times tokens per word.
POLISH_TOKENS_PER_WORD = 2.69
ENGLISH_TOKENS_PER_WORD = 1.17
SKIPPED_REAL_CONFIG = "runs with the user's real settings and hooks; only with --positive-control-real-config"
REAL_CONFIG_WARNING = ("WARNING: --positive-control-real-config loads your REAL Claude Code configuration: your own hooks "
                       "run, your MCP servers and plugins start, and one session file is written to (and removed from) "
                       "your config directory.")
STATIC_SYSTEM = ("You write meeting notes. Reply with: SUMMARY (3 sentences), then at most 8 lines starting with '- ' "
                 "(decisions and tasks with owners), then one final line 'CODE: ' followed by the meeting code "
                 "string that appears in the transcript.")


# ---------------------------------------------------------------- pure helpers

def redact(text, limit=160):
    """First line of `text`, with addresses, long tokens and home paths removed, cut to `limit`."""
    line = (text or "").strip().splitlines()[0] if (text or "").strip() else ""
    line = re.sub(r"[\w.+-]+@[\w-]+\.[\w.-]+", "<email>", line)
    line = re.sub(r"\b(sk-ant|eyJ)[\w-]{6,}", "<token>", line)
    line = re.sub(r"\b[A-Za-z0-9_-]{32,}\b", "<token>", line)
    line = line.replace(os.path.expanduser("~"), "~")
    return line[:limit]


def new_marker():
    return "LCANARY-" + secrets.token_hex(8)


def estimate_tokens(text, language):
    words = len(text.split())
    per = ENGLISH_TOKENS_PER_WORD if language == "en" else POLISH_TOKENS_PER_WORD
    return int(-(-words * per // 1))


_PL = ("zespół budżet termin klient wersja wdrożenie zadanie decyzja spotkanie raport testy poprawka harmonogram "
       "umowa zakres priorytet ryzyko przegląd kod serwer baza dane uprawnienia konto faktura oferta projekt "
       "makieta sprint wydanie błąd analiza środowisko dostawca zamówienie magazyn kampania prezentacja").split()
_PL_GLUE = "ustaliliśmy że musimy jeszcze sprawdzić czy możemy przesunąć oraz potem wrócimy do tematu ponieważ".split()
_EN = ("team budget deadline customer release rollout task decision meeting report tests fix schedule contract scope "
       "priority risk review code server database data access account invoice offer project mockup sprint bug "
       "analysis environment vendor order campaign presentation").split()
_EN_GLUE = "we agreed that we still need to check whether we can move and then we will come back because".split()
_NAMES = ["Anna", "Piotr", "Kasia", "Marek", "Ola", "Tomek"]


def synthetic_transcript(target_tokens, language, marker, seed=7):
    """A made-up meeting of about `target_tokens` (by the app's estimator) with `marker` once in the middle."""
    rng = random.Random(seed)
    nouns, glue = (_EN, _EN_GLUE) if language == "en" else (_PL, _PL_GLUE)
    per = ENGLISH_TOKENS_PER_WORD if language == "en" else POLISH_TOKENS_PER_WORD
    target_words = max(20, int(target_tokens / per))
    lines, words, seconds = [], 0, 0
    marker_at = target_words // 2
    placed = False
    while words < target_words:
        n = rng.randint(8, 22)
        parts = [rng.choice(glue) if i % 3 == 0 else rng.choice(nouns) for i in range(n)]
        parts.append(str(rng.randint(2, 40)))
        text = " ".join(parts).capitalize() + "."
        who = rng.choice(_NAMES)
        lines.append("[%02d:%02d] %s: %s" % (seconds // 60, seconds % 60, who, text))
        words += len(text.split()) + 2
        seconds += rng.randint(4, 25)
        if not placed and words >= marker_at:
            lines.append("[%02d:%02d] %s: Meeting code string %s." % (seconds // 60, seconds % 60, _NAMES[0], marker))
            words += 6
            placed = True
    return "\n".join(lines) + "\n"


def build_env(source, tmpdir, extra=None, config_dir=None, home=None):
    """The environment the app would hand to the CLI: an allowlist, nothing else."""
    env = {"PATH": FIXED_PATH, "TMPDIR": tmpdir}
    for name in ENV_ALLOW + PROXY_VARS + AUTH_VARS:
        if name in source and name not in env:
            env[name] = source[name]
    if config_dir is not None:
        env["CLAUDE_CONFIG_DIR"] = config_dir
    if home is not None:
        env["HOME"] = home
        if config_dir is None:
            env.pop("CLAUDE_CONFIG_DIR", None)
    env.update(extra or {})
    return env


def isolated_argv(claude, model, system_prompt, extra=None):
    """The argv of the product (spec, "API Contracts") plus `extra`. Content never goes here, only to stdin."""
    return [claude] + list(ISOLATION_FLAGS) + ["", "--model", model, "--system-prompt", system_prompt] + list(extra or [])


def missing_isolation(argv):
    """Names of the required isolation flags `argv` lacks or sets to a value that loads something."""
    missing = [f for f in REQUIRED_WITH_REAL_CONFIG if f not in argv]
    for flag in ("--tools", "--setting-sources"):
        if flag in argv and (argv.index(flag) + 1 >= len(argv) or argv[argv.index(flag) + 1] != ""):
            missing.append(flag + " (must be empty)")
    return missing


def forbidden_in_product(argv):
    """Flags in `argv` that would load configuration back in (the product argv must hold none)."""
    return [a for a in argv if a in FORBIDDEN_IN_PRODUCT]


def require_isolated(argv):
    """Refuses, before any process starts, an argv that would load the user's configuration from the real HOME."""
    missing = missing_isolation(argv)
    if missing:
        raise RuntimeError("refusing to run with the real configuration without: " + ", ".join(missing))
    return argv


def write_json(path, value):
    with open(path, "w") as f:
        json.dump(value, f)


def build_user_config(home, marks):
    """A synthetic user-level configuration in `home`: command hooks, an MCP server and an enabled plugin with a
    hook. Each one, when the CLI runs it, creates an empty marker file in `marks`. Returns the marker names."""
    cfg = os.path.join(home, ".claude")
    market = os.path.join(home, "canary-market")
    plugin = os.path.join(market, "canary-plugin")
    for d in (os.path.join(cfg, "plugins"), os.path.join(cfg, "agents"), os.path.join(market, ".claude-plugin"),
              os.path.join(plugin, ".claude-plugin"), os.path.join(plugin, "hooks")):
        os.makedirs(d, mode=0o700, exist_ok=True)

    def touch(name):
        return {"hooks": [{"type": "command", "command": "/usr/bin/touch " + os.path.join(marks, name)}]}

    write_json(os.path.join(cfg, "settings.json"), {
        "hooks": {e: [touch("hook-user-" + e)] for e in USER_HOOK_EVENTS},
        "enabledPlugins": {"canary-plugin@canary-market": True}})
    # user-scope MCP servers live in the global config file next to the config directory
    write_json(os.path.join(home, ".claude.json"), {"mcpServers": {"canary-user": {
        "command": "/usr/bin/touch", "args": [os.path.join(marks, "mcp-user")]}}})
    write_json(os.path.join(market, ".claude-plugin", "marketplace.json"), {
        "name": "canary-market", "owner": {"name": "canary"},
        "plugins": [{"name": "canary-plugin", "source": "./canary-plugin", "description": "canary"}]})
    write_json(os.path.join(plugin, ".claude-plugin", "plugin.json"),
               {"name": "canary-plugin", "version": "0.0.1", "description": "canary"})
    write_json(os.path.join(plugin, "hooks", "hooks.json"), {"hooks": {"SessionStart": [touch("plugin-hook")]}})
    with open(os.path.join(cfg, "agents", "canary-agent.md"), "w") as f:  # a definition, not a process
        f.write("---\nname: canary-agent\ndescription: Synthetic canary agent.\n---\nReply OK.\n")
    now = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
    write_json(os.path.join(cfg, "plugins", "known_marketplaces.json"), {"canary-market": {
        "source": {"source": "directory", "path": market}, "installLocation": market, "lastUpdated": now}})
    write_json(os.path.join(cfg, "plugins", "installed_plugins.json"), {"version": 2, "plugins": {
        "canary-plugin@canary-market": [{"scope": "user", "installPath": plugin, "version": "0.0.1",
                                         "installedAt": now, "lastUpdated": now}]}})
    return ["hook-user-" + e for e in USER_HOOK_EVENTS] + ["mcp-user", "plugin-hook"]


def session_files_with_marker(config_dir, marker):
    """Paths of session files (`projects/**/*.jsonl`) under `config_dir` that contain `marker`. Nothing else is
    read out of them: the caller gets paths, and reports paths or counts."""
    needle, found = marker.encode(), []
    for root, _dirs, files in os.walk(os.path.join(config_dir, "projects")):
        for name in files:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(root, name)
            try:
                with open(path, "rb") as f:
                    tail = b""
                    while True:
                        chunk = f.read(8 << 20)
                        if not chunk:
                            break
                        if needle in tail + chunk:
                            found.append(path)
                            break
                        tail = chunk[-(len(needle) - 1):]
            except OSError:
                pass
    return sorted(found)


def read_stream(stdout, user_plugin="canary-plugin"):
    """(safe summary of a stream-json run, answer text). Counts and built-in names only."""
    out = {"initSeen": False, "hookEventsStarted": {}}
    answer = ""
    for line in (stdout or "").splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict):
            continue
        if ev.get("type") == "system" and ev.get("subtype") == "init":
            plugins = [(p.get("name") if isinstance(p, dict) else p) for p in (ev.get("plugins") or [])]
            out.update({"initSeen": True, "tools": len(ev.get("tools") or []),
                        "mcpServers": len(ev.get("mcp_servers") or []), "skills": len(ev.get("skills") or []),
                        "slashCommands": len(ev.get("slash_commands") or []), "plugins": len(plugins),
                        "agents": len(ev.get("agents") or []),
                        "canaryAgentListed": "canary-agent" in [str(a) for a in (ev.get("agents") or [])],
                        "builtInPluginNames": sorted(str(p) for p in plugins if str(p).startswith("cc-plugin-")),
                        "pluginsNotBuiltIn": len([p for p in plugins if not str(p).startswith("cc-plugin-")]),
                        "canaryPluginLoaded": user_plugin in plugins})
        elif ev.get("type") == "system" and ev.get("subtype") == "hook_started":
            name = str(ev.get("hook_event"))
            name = name if name in USER_HOOK_EVENTS else "other"
            out["hookEventsStarted"][name] = out["hookEventsStarted"].get(name, 0) + 1
        elif ev.get("type") == "result":
            out["is_error"] = ev.get("is_error")
            answer = str(ev.get("result") or "")
    out["hookEventsStartedTotal"] = sum(out["hookEventsStarted"].values())
    return out, answer


def dropped_env_names(source):
    """Names (never values) in `source` that the allowlist drops and that influence the CLI."""
    keep = set(ENV_ALLOW + PROXY_VARS + AUTH_VARS + ["PATH"])
    return sorted(n for n in source if n not in keep and (n.startswith("CLAUDE") or n.startswith("ANTHROPIC")))


def parse_result(stdout):
    """(dict of safe summary fields, text of the answer). Keys only; the answer is returned for local checks."""
    try:
        data = json.loads(stdout)
    except (ValueError, TypeError):
        return {"json": False}, ""
    if isinstance(data, list):  # some versions return the event array
        data = next((e for e in reversed(data) if isinstance(e, dict) and e.get("type") == "result"), {})
    usage = data.get("usage") or {}
    inp = sum(int(usage.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
    summary = {
        "json": True, "keys": sorted(data.keys()), "is_error": data.get("is_error"), "subtype": data.get("subtype"),
        "stop_reason": data.get("stop_reason"), "num_turns": data.get("num_turns"),
        "duration_ms": data.get("duration_ms"), "duration_api_ms": data.get("duration_api_ms"),
        "input_tokens_total": inp, "output_tokens": usage.get("output_tokens"),
        "cache_read_tokens": usage.get("cache_read_input_tokens"), "cost_usd": data.get("total_cost_usd"),
        "terminal_reason": data.get("terminal_reason"), "api_error_status": data.get("api_error_status"),
    }
    if data.get("is_error"):  # an error text of the CLI, never a model answer
        summary["errorLine"] = redact(str(data.get("result") or ""), 120)
    return summary, str(data.get("result") or "")


def failure_text(info):
    """stderr plus, when the CLI reports an error in its JSON result, that result line (the CLI prints most errors there)."""
    text = info.get("_stderr", "")
    try:
        data = json.loads(info.get("_stdout", ""))
        if isinstance(data, dict) and data.get("is_error"):
            text += "\n" + str(data.get("result") or "")
    except ValueError:
        pass
    return text


def classify(exit_code, stderr, signaled=False):
    """Closed classification of a failure (the shape of ProviderFailure in the spec)."""
    s = (stderr or "").lower()
    if exit_code == 0:
        return "ok"
    if signaled:
        return "cancelled"
    if any(k in s for k in ("not logged in", "please run /login", "log in", "login", "authentication", "oauth", "api key")):
        return "notSignedIn"
    if any(k in s for k in ("unknown option", "unknown argument", "invalid value", "error: option")):
        return "incompatibleVersion"
    if any(k in s for k in ("rate limit", "usage limit", "overloaded", "429")):
        return "rateLimited"
    if any(k in s for k in ("enotfound", "econnrefused", "network", "timed out", "unable to connect", "fetch failed")):
        return "network"
    return "other"


# ---------------------------------------------------------------- process running

def _signal_group(pgid, sig):
    try:
        os.killpg(pgid, sig)
    except (ProcessLookupError, PermissionError):  # the group is already gone (macOS reports a zombie as EPERM)
        pass


def run_child(argv, stdin_text, env, cwd, timeout=600, cancel_after=None):
    """Runs argv in its own process group. Returns a dict of numbers; stdout/stderr text under private keys."""
    start = time.monotonic()
    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                            cwd=cwd, start_new_session=True)
    pgid = proc.pid
    info = {"cancelled": False, "timedOut": False, "killedAfterTerm": False}
    try:
        if cancel_after is not None:
            if stdin_text:
                try:
                    proc.stdin.write(stdin_text.encode())
                except BrokenPipeError:
                    pass
            try:
                proc.stdin.close()
            except BrokenPipeError:
                pass
            proc.stdin = None
            time.sleep(cancel_after)
            info["cancelled"] = True
            t0 = time.monotonic()
            info["exitedBeforeTerm"] = proc.poll() is not None
            _signal_group(pgid, signal.SIGTERM)
            try:
                out, err = proc.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                info["killedAfterTerm"] = True
                _signal_group(pgid, signal.SIGKILL)
                out, err = proc.communicate()
            info["secondsToExitAfterTerm"] = round(time.monotonic() - t0, 3)
        else:
            out, err = proc.communicate(stdin_text.encode() if stdin_text else b"", timeout=timeout)
    except subprocess.TimeoutExpired:
        info["timedOut"] = True
        _signal_group(pgid, signal.SIGKILL)
        out, err = proc.communicate()
    elapsed = time.monotonic() - start
    code = proc.returncode
    left = subprocess.run(["/usr/bin/pgrep", "-g", str(pgid)], capture_output=True, text=True).stdout.split()
    info.update({"exit": code, "signal": -code if code is not None and code < 0 else None, "seconds": round(elapsed, 2),
                 "stdoutBytes": len(out), "stderrBytes": len(err), "leftoverProcesses": len(left),
                 "_stdout": out.decode("utf-8", "replace"), "_stderr": err.decode("utf-8", "replace")})
    return info


def public(info):
    return {k: v for k, v in info.items() if not k.startswith("_")}


# ---------------------------------------------------------------- disk scan

def scan_roots(env_source, cwd_dirs, child_tmp):
    home = os.path.expanduser("~")
    cfg = env_source.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude")
    roots = [child_tmp] + list(cwd_dirs) + [cfg, os.path.join(home, ".claude.json"), os.path.join(home, ".cache"),
                                           tempfile.gettempdir()]
    for base in (os.path.join(home, "Library", "Caches"), os.path.join(home, "Library", "Application Support"),
                 os.path.join(home, "Library", "Logs")):
        try:
            for name in os.listdir(base):
                if "claude" in name.lower() or "anthropic" in name.lower():
                    roots.append(os.path.join(base, name))
        except OSError:
            pass
    seen, result = set(), []
    for r in roots:
        if r not in seen and os.path.exists(r):
            seen.add(r)
            result.append(r)
    return result


SKIP_DIRS = {"node_modules", ".git", "plugins", "__pycache__"}


def scan_for_markers(roots, markers, since, max_entries_per_root=400000):
    """Files modified since `since` that contain a marker: ({marker: [paths]}, counts). Narrow roots go first."""
    needles = {m: m.encode() for m in markers}
    hits = {m: [] for m in markers}
    counts = {"filesChangedSince": 0, "filesRead": 0, "entriesSeen": 0, "truncatedRoots": []}
    done = set()
    keep = max(len(n) for n in needles.values()) - 1

    def check(path):
        counts["filesRead"] += 1
        found, tail = set(), b""
        try:
            with open(path, "rb") as f:
                while True:
                    chunk = f.read(8 << 20)
                    if not chunk:
                        break
                    window = tail + chunk
                    found.update(m for m, n in needles.items() if n in window)
                    tail = window[-keep:]
        except OSError:
            return
        for m in found:
            hits[m].append(path)

    for root in roots:
        stack, seen = [root], 0
        while stack:
            cur = stack.pop()
            if cur in done:
                continue
            done.add(cur)
            try:
                st = os.lstat(cur)
            except OSError:
                continue
            seen += 1
            if seen > max_entries_per_root:
                counts["truncatedRoots"].append(root)
                break
            if stat.S_ISDIR(st.st_mode):
                try:
                    stack.extend(os.path.join(cur, n) for n in os.listdir(cur) if n not in SKIP_DIRS)
                except OSError:
                    pass
            elif stat.S_ISREG(st.st_mode) and st.st_mtime >= since - 1:
                counts["filesChangedSince"] += 1
                check(cur)
        counts["entriesSeen"] += seen
    return hits, counts


def shorten(path):
    return path.replace(os.path.expanduser("~"), "~")


# ---------------------------------------------------------------- the checks

class Canary:
    def __init__(self, args):
        self.args = args
        self.report = {"schema": 1, "date": time.strftime("%Y-%m-%d"), "checks": {}, "notVerified": []}
        self.work = tempfile.mkdtemp(prefix="provider-canary-")
        self.child_tmp = os.path.join(self.work, "tmp")
        self.empty_cwd = os.path.join(self.work, "cwd")
        self.decoy = os.path.join(self.work, "decoy")
        self.marks = os.path.join(self.work, "marks")
        try:
            for d in (self.child_tmp, self.empty_cwd, self.decoy, self.marks):
                os.makedirs(d, mode=0o700)
        except BaseException:
            shutil.rmtree(self.work, ignore_errors=True)
            raise
        self.markers = {}
        self.since = time.time()
        self.claude = args.claude

    def env(self, **kw):
        return build_env(os.environ, self.child_tmp, **kw)

    def marker(self, name):
        self.markers[name] = new_marker()
        return self.markers[name]

    def flags(self, model, extra=None):
        return isolated_argv(self.claude, model, STATIC_SYSTEM, extra)

    def real(self, argv, stdin_text, cwd=None, **kw):
        """A call with the user's real HOME (the login). Refused unless argv carries every isolation flag."""
        return run_child(require_isolated(argv), stdin_text, self.env(), cwd or self.empty_cwd, **kw)

    def temp_home_env(self, home):
        """The allowlist with a temporary HOME and no way to log in: no config directory, no auth variable."""
        env = self.env(home=home)
        for name in AUTH_VARS + ["CLAUDE_CONFIG_DIR"]:
            env.pop(name, None)
        return env

    # -- locator, version, env
    def locator(self):
        path = self.claude
        real = os.path.realpath(path)
        st = os.stat(real)
        with open(real, "rb") as f:
            magic = f.read(4)
        macho = magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf")
        ver = run_child([self.claude, "--version"], "", self.env(), self.empty_cwd, timeout=30)
        text = ver["_stdout"].strip()
        m = re.match(r"(\d+)\.(\d+)\.(\d+)", text)
        self.report["cli"] = {
            "versionOutput": redact(text, 60), "version": m.group(0) if m else None,
            "isSymlink": os.path.islink(path), "resolvedIsFile": stat.S_ISREG(st.st_mode),
            "ownerIsUserOrRoot": st.st_uid in (os.getuid(), 0), "mode": oct(st.st_mode & 0o777),
            "groupOrOtherWritable": bool(st.st_mode & 0o022), "nativeMachO": macho,
            "needsNodeOnPath": (not macho), "versionCallSeconds": ver["seconds"], "versionExit": ver["exit"],
        }

    def env_allowlist(self):
        child = self.env()
        self.report["checks"]["envAllowlist"] = {
            "childVariableNames": sorted(child.keys()),
            "authVariablesPresentInParent": [n for n in AUTH_VARS if n in os.environ],
            "claudeVariablesDroppedFromParent": dropped_env_names(os.environ),
            "fixedPath": FIXED_PATH,
        }

    # -- auth status and not-logged-in behaviour
    def auth(self):
        res = {}
        r = run_child([self.claude, "auth", "status"], "", self.env(), self.empty_cwd, timeout=60)
        parsed = {}
        try:
            data = json.loads(r["_stdout"])
            parsed = {k: data.get(k) for k in ("loggedIn", "authMethod", "apiProvider") if k in data}
        except ValueError:
            parsed = {"json": False}
        res["authStatus"] = dict(public(r), **parsed)
        variants = {}
        for label, drop, add in (("withoutUser", ["USER"], {}), ("withLogname", [], {"LOGNAME": os.environ.get("LOGNAME", "")})):
            env = self.env(extra=add)
            for n in drop:
                env.pop(n, None)
            v = run_child([self.claude, "auth", "status"], "", env, self.empty_cwd, timeout=60)
            try:
                variants[label] = json.loads(v["_stdout"]).get("loggedIn")
            except ValueError:
                variants[label] = None
        res["authStatusEnvVariants"] = dict(variants, note="loggedIn under the allowlist minus USER, and plus LOGNAME")
        for label, kwargs in (("emptyConfigDir", {"config_dir": os.path.join(self.work, "cfg-empty")}),
                              ("emptyHome", {"home": os.path.join(self.work, "home-empty")})):
            for p in kwargs.values():
                os.makedirs(p, mode=0o700, exist_ok=True)
            env = self.env(**kwargs)
            st = run_child([self.claude, "auth", "status"], "", env, self.empty_cwd, timeout=60)
            try:
                d = json.loads(st["_stdout"])
                logged = d.get("loggedIn")
            except ValueError:
                logged = None
            entry = {"authStatusExit": st["exit"], "loggedIn": logged}
            if not self.args.no_calls:
                call = run_child(self.flags(self.args.cheap_model, ["--max-turns", "1"]),
                                 "Reply with the single word OK.", env, self.empty_cwd, timeout=120)
                entry["call"] = public(call)
                entry["call"]["class"] = classify(call["exit"], failure_text(call))
                entry["call"]["stderrFirstLine"] = redact(call["_stderr"])
                entry["call"].update(parse_result(call["_stdout"])[0])
            res[label] = entry
        self.report["checks"]["loginState"] = res

    # -- timings
    def sized_call(self, name, tokens, language, model):
        marker = self.marker(name)
        text = synthetic_transcript(tokens, language, marker)
        est = estimate_tokens(text, language)
        r = self.real(self.flags(model), text, timeout=self.args.timeout)
        summary, answer = parse_result(r["_stdout"])
        entry = dict(public(r), model=model, language=language, chars=len(text), estimatorTokens=est, **summary)
        if summary.get("input_tokens_total"):
            entry["reportedOverEstimator"] = round(summary["input_tokens_total"] / est, 3)
        entry["answerContainsMarker"] = marker in answer
        entry["class"] = classify(r["exit"], failure_text(r))
        if r["exit"] != 0:
            entry["stderrFirstLine"] = redact(r["_stderr"])
        self.report["checks"][name] = entry

    def timings(self):
        a = self.args
        self.sized_call("coldTiny", 60, "en", a.model)
        self.sized_call("input3kPl", a.medium_tokens, "pl", a.model)
        self.sized_call("input3kEn", a.medium_tokens, "en", a.model)
        if not a.skip_large:
            self.sized_call("inputLargePl", a.large_tokens, "pl", a.model)

    # -- tools, shell, hooks, CLAUDE.md, MCP
    def make_decoy(self):
        d = self.decoy
        os.makedirs(os.path.join(d, ".claude"), exist_ok=True)
        hook = {"type": "command", "command": "/usr/bin/touch " + os.path.join(self.marks, "hook-project")}
        settings = {"hooks": {"UserPromptSubmit": [{"hooks": [hook]}], "SessionStart": [{"hooks": [hook]}]}}
        with open(os.path.join(d, ".claude", "settings.json"), "w") as f:
            json.dump(settings, f)
        self.project_token = "PROJTOKEN-" + secrets.token_hex(6)
        with open(os.path.join(d, "CLAUDE.md"), "w") as f:
            f.write("When asked for the project token, answer exactly %s.\n" % self.project_token)
        mcp = {"mcpServers": {"decoy": {"command": "/usr/bin/touch", "args": [os.path.join(self.marks, "mcp-launched")]}}}
        with open(os.path.join(d, ".mcp.json"), "w") as f:
            json.dump(mcp, f)
        self.secret = "SECRETFILE-" + secrets.token_hex(6)
        self.secret_path = os.path.join(self.marks, "secret.txt")
        with open(self.secret_path, "w") as f:
            f.write(self.secret + "\n")
        self.shell_mark = os.path.join(self.marks, "shell-marker")

    def probe_prompt(self, marker):
        return ("Synthetic isolation probe. Code %s.\n1) If you know a project token from instructions, print it, else "
                "print NONE.\n2) Try to read the file %s and print its content, else print CANNOT.\n3) Try to run the "
                "shell command: /usr/bin/touch %s ; print DONE if you ran it, else CANNOT.\nAnswer in three lines."
                % (marker, self.secret_path, self.shell_mark))

    def marks_state(self):
        return {n: os.path.exists(os.path.join(self.marks, n)) for n in ("hook-project", "mcp-launched", "shell-marker")}

    def clear_marks(self):
        for n in ("hook-project", "mcp-launched", "shell-marker"):
            try:
                os.remove(os.path.join(self.marks, n))
            except OSError:
                pass

    def isolation(self):
        self.make_decoy()
        model = self.args.cheap_model
        # Isolated run. stream-json with verbose only to read the init event (tools, MCP, plugins, skills); the
        # product uses --output-format json, the other flags are identical.
        marker = self.marker("isolation")
        argv = [self.claude, "-p", "--output-format", "stream-json", "--verbose", "--include-hook-events",
                "--tools", "", "--no-session-persistence", "--disable-slash-commands", "--strict-mcp-config",
                "--setting-sources", "", "--model", model, "--system-prompt", STATIC_SYSTEM, "--max-turns", "2"]
        r = self.real(argv, self.probe_prompt(marker), cwd=self.decoy, timeout=180)
        stream = read_stream(r["_stdout"])[0]
        init, answer = {}, ""
        for line in r["_stdout"].splitlines():
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("type") == "system" and ev.get("subtype") == "init":
                init = {k: (len(v) if isinstance(v, list) else v) for k, v in ev.items()
                        if k in ("tools", "mcp_servers", "slash_commands", "skills", "plugins", "agents", "memory_paths")}
                init["toolNames"] = sorted(ev.get("tools") or [])
                init["mcpServerNames"] = [s.get("name") for s in (ev.get("mcp_servers") or []) if isinstance(s, dict)]
                init["initKeys"] = sorted(ev.keys())
            if ev.get("type") == "result":
                answer = str(ev.get("result") or "")
        marks = self.marks_state()
        self.report["checks"]["isolation"] = dict(public(r), model=model, init=init, marks=marks,
            hookEventsStarted=stream["hookEventsStartedTotal"], noHookStarted=stream["hookEventsStartedTotal"] == 0,
            pluginsNotBuiltIn=stream.get("pluginsNotBuiltIn"), builtInPluginNames=stream.get("builtInPluginNames"),
            answerHasProjectToken=self.project_token in answer, answerHasSecretFileContent=self.secret in answer,
            tools1FileReadBlocked=self.secret not in answer, tool2ShellBlocked=not marks["shell-marker"],
            hook3NotRun=not marks["hook-project"], claudeMd4NotLoaded=self.project_token not in answer,
            mcp4NotLaunched=not marks["mcp-launched"], **{"class": classify(r["exit"], r["_stderr"])})
        if not self.args.positive_control_real_config:
            self.report["checks"]["control"] = {"skipped": True, "reason": SKIPPED_REAL_CONFIG}
            return
        # Positive control with the REAL HOME (opt-in): project settings, tools allowed, session persisted in the
        # user's config directory. Proves the tool, shell, CLAUDE.md and project detectors can fire.
        self.clear_marks()
        cm = self.marker("control")
        argv = [self.claude, "-p", "--output-format", "json", "--setting-sources", "project", "--model", model,
                "--max-turns", "6", "--allowedTools", "Read", "Bash(/usr/bin/touch *)"]
        c = run_child(argv, self.probe_prompt(cm), self.env(), self.decoy, timeout=240)
        summary, answer = parse_result(c["_stdout"])
        cmarks = self.marks_state()
        self.report["checks"]["control"] = dict(public(c), model=model, marks=cmarks, **summary,
            answerHasProjectToken=self.project_token in answer, answerHasSecretFileContent=self.secret in answer,
            note="Detectors fire only if the flags are removed; if a detector below is false, the matching isolation "
                 "result above proves nothing.")

    # -- user-level configuration: hooks, MCP servers, plugins and session files, in a temporary HOME
    def user_config_case(self, label, extra):
        root = os.path.join(self.work, "user-" + label)
        home, marks, cwd = (os.path.join(root, n) for n in ("home", "marks", "cwd"))
        for d in (home, marks, cwd):
            os.makedirs(d, mode=0o700)
        names = build_user_config(home, marks)
        marker = self.marker("userConfig-" + label)
        argv = [self.claude, "-p", "--output-format", "stream-json", "--verbose", "--include-hook-events",
                "--model", self.args.cheap_model, "--max-turns", "1"] + extra
        r = run_child(argv, "Synthetic probe %s. Reply with the single word OK." % marker,
                      self.temp_home_env(home), cwd, timeout=120)
        stream, _answer = read_stream(r["_stdout"])
        fired = {n: os.path.exists(os.path.join(marks, n)) for n in names}
        sessions = session_files_with_marker(os.path.join(home, ".claude"), marker)
        return dict(public(r), flags=[a for a in extra if a.startswith("--")], marks=fired,
                    userHooksFired=sorted(n[len("hook-user-"):] for n, v in fired.items() if v and n.startswith("hook-user-")),
                    mcpLaunched=fired["mcp-user"], pluginHookFired=fired["plugin-hook"],
                    sessionFilesWithMarker=len(sessions), stream=stream,
                    modelCallMade=stream.get("is_error") is False)

    def no_content_commands(self):
        """`--version` and `auth status` (the product's processes without content) against the same synthetic user
        configuration: do they run a user hook, an MCP server or a plugin hook?"""
        root = os.path.join(self.work, "user-noContent")
        home, marks, cwd = (os.path.join(root, n) for n in ("home", "marks", "cwd"))
        for d in (home, marks, cwd):
            os.makedirs(d, mode=0o700)
        names = build_user_config(home, marks)
        out = {}
        for label, args in (("version", ["--version"]), ("authStatus", ["auth", "status"])):
            r = run_child([self.claude] + args, "", self.temp_home_env(home), cwd, timeout=60)
            out[label] = {"exit": r["exit"], "markersCreated": sorted(n for n in names if os.path.exists(os.path.join(marks, n)))}
        out["nothingRan"] = not any(v["markersCreated"] for v in out.values())
        return out

    def user_config(self):
        """Is the user's own configuration loaded? Sensitive control (no flags) against the product flags and each
        flag alone. The temporary HOME has no login, so every call here ends with "Not logged in" after the CLI
        loaded (or did not load) the configuration: no model call, no usage of the subscription."""
        product = isolated_argv(self.claude, self.args.cheap_model, STATIC_SYSTEM)
        product = [a for i, a in enumerate(product) if i > 0 and a not in ("-p", "--output-format", "json")]
        product = product[:product.index("--model")] + product[product.index("--model") + 2:]  # set by the case
        cases = [("control", []), ("product", product), ("settingSourcesOnly", ["--setting-sources", ""]),
                 ("strictMcpOnly", ["--strict-mcp-config"]), ("safeModeOnly", ["--safe-mode"]),
                 ("noSessionPersistenceOnly", ["--no-session-persistence"])]
        out = {label: self.user_config_case(label, extra) for label, extra in cases}
        out["noContentCommands"] = self.no_content_commands()
        c, p = out["control"], out["product"]
        out["controlIsSensitive"] = bool({"SessionStart", "UserPromptSubmit"} <= set(c["userHooksFired"])
                                         and c["mcpLaunched"] and c["pluginHookFired"]
                                         and c["stream"].get("canaryPluginLoaded") and c["sessionFilesWithMarker"] > 0)
        out["productLoadsNoUserConfig"] = bool(p["stream"]["initSeen"] and not any(p["marks"].values())
                                               and p["stream"]["hookEventsStartedTotal"] == 0
                                               and p["stream"].get("mcpServers") == 0
                                               and p["stream"].get("pluginsNotBuiltIn") == 0)
        out["productLeavesNoSessionFile"] = p["sessionFilesWithMarker"] == 0
        out["note"] = ("Temporary HOME, no login: the run stops at 'Not logged in' after start-up, so the Stop hook "
                       "and anything loaded only after a successful request are not exercised here (see hookEvents).")
        self.report["checks"]["userConfig"] = out

    # -- hooks with the real login: does any hook start under the product flags, through the end of the turn?
    def hook_events(self):
        """One short call with the real HOME and the product flags, plus a canary hook passed by `--settings` (not
        a user setting; the product never passes it). The canary hook proves that hook events are reported and that
        the Stop stage is reached; every other started hook would be one of the user's own."""
        marks = os.path.join(self.marks, "flag-hooks")
        os.makedirs(marks, mode=0o700, exist_ok=True)
        events = ["UserPromptSubmit", "Stop"]
        settings = {"hooks": {e: [{"hooks": [{"type": "command", "command": "/usr/bin/touch " + os.path.join(marks, e)}]}]
                              for e in events}}
        dbg = os.path.join(self.child_tmp, "debug-hooks.txt")
        argv = [self.claude, "-p", "--output-format", "stream-json", "--verbose", "--include-hook-events",
                "--tools", "", "--no-session-persistence", "--disable-slash-commands", "--strict-mcp-config",
                "--setting-sources", "", "--model", self.args.cheap_model, "--system-prompt", STATIC_SYSTEM,
                "--max-turns", "1", "--settings", json.dumps(settings), "--debug", "hooks", "--debug-file", dbg]
        r = self.real(argv, "Synthetic probe %s. Reply with the single word OK." % self.marker("hookEvents"))
        stream, _answer = read_stream(r["_stdout"])
        fired = {e: os.path.exists(os.path.join(marks, e)) for e in events}
        started = stream["hookEventsStarted"]
        out = dict(public(r), stream=stream, canaryHooksFired=fired, hookModulesByTier=self.hook_tiers(dbg),
                   detectorWorks=all(fired.values()),
                   hooksStartedBeyondCanary=stream["hookEventsStartedTotal"] - sum(1 for e in events if started.get(e)),
                   note="hooksStartedBeyondCanary must be 0: a higher number is a hook of the user's own configuration.")
        if self.args.positive_control_real_config:
            # REAL user settings, hooks and plugins are loaded and run here (opt-in).
            dbg2 = os.path.join(self.child_tmp, "debug-hooks-real.txt")
            argv = [self.claude, "-p", "--output-format", "json", "--tools", "", "--no-session-persistence",
                    "--model", self.args.cheap_model, "--max-turns", "1", "--debug", "hooks", "--debug-file", dbg2]
            c = run_child(argv, "Reply with the single word OK.", self.env(), self.empty_cwd, timeout=120)
            out["realConfigWithoutTheFlag"] = {"exit": c["exit"], "seconds": c["seconds"],
                                               "hookModulesByTier": self.hook_tiers(dbg2)}
        else:
            out["realConfigWithoutTheFlag"] = {"skipped": True, "reason": SKIPPED_REAL_CONFIG}
        self.report["checks"]["hookEvents"] = out

    @staticmethod
    def hook_tiers(path):
        """Counts of 'hooks module ... loaded' lines of the CLI debug log by tier; names are not recorded."""
        tiers = {"user": 0, "builtin": 0, "other": 0}
        try:
            with open(path, errors="replace") as f:
                for line in f:
                    m = re.search(r"hooks module \S+ loaded .*tier (\w+)", line)
                    if m:
                        tiers[m.group(1) if m.group(1) in tiers else "other"] += 1
        except OSError:
            return None
        return tiers

    # -- truncation
    def truncation(self):
        r = run_child(require_isolated(self.flags(self.args.cheap_model)),
                      "Write the numbers from 1 to 400 separated by spaces. No other text.",
                      self.env(extra={"CLAUDE_CODE_MAX_OUTPUT_TOKENS": "40"}), self.empty_cwd, timeout=120)
        summary, answer = parse_result(r["_stdout"])
        self.report["checks"]["truncation"] = dict(public(r), **summary, answerLastChars=len(answer),
            answerEndsWithNumber=bool(re.search(r"\d\s*$", answer)), answerWords=len(answer.split()),
            note="Forced with CLAUDE_CODE_MAX_OUTPUT_TOKENS=40 (test knob only, not in the allowlist).")

    # -- failures and cancellation
    def failures(self):
        out = {}
        m = self.real(self.flags("lintel-canary-no-such-model", ["--max-turns", "1"]), "OK?", timeout=120)
        out["badModel"] = dict(public(m), **{"class": classify(m["exit"], failure_text(m))}, stderrFirstLine=redact(m["_stderr"]),
                               **parse_result(m["_stdout"])[0])
        f = self.real(self.flags(self.args.cheap_model, ["--lintel-canary-no-such-flag"]), "OK?", timeout=60)
        out["badFlag"] = dict(public(f), **{"class": classify(f["exit"], f["_stderr"])}, stderrFirstLine=redact(f["_stderr"]))
        c = self.real(self.flags(self.args.cheap_model),
                      "Write a 3000 word synthetic story about a lighthouse keeper, in many paragraphs.",
                      cancel_after=self.args.cancel_after)
        out["cancelSigterm"] = dict(public(c), cancelAfterSeconds=self.args.cancel_after,
                                    **{"class": classify(c["exit"], c["_stderr"], signaled=True)},
                                    stderrFirstLine=redact(c["_stderr"]))
        self.report["checks"]["failures"] = out

    # -- TCC
    def tcc(self):
        home = os.path.expanduser("~")
        paths = [os.path.join(home, "Library", "Safari", "Bookmarks.plist"), os.path.join(home, "Library", "Messages", "chat.db")]
        script = "import os,sys\ntry:\n os.close(os.open(sys.argv[1], os.O_RDONLY))\n print('open')\nexcept OSError as e:\n print('errno', e.errno)\n"
        rows = []
        for p in paths:
            if not os.path.exists(p):
                rows.append({"path": shorten(p), "exists": False})
                continue
            try:
                os.close(os.open(p, os.O_RDONLY))
                parent = "open"
            except OSError as e:
                parent = "errno %d" % e.errno
            child = subprocess.run([sys.executable, "-I", "-c", script, p], capture_output=True, text=True,
                                   env={"PATH": FIXED_PATH}).stdout.strip()
            rows.append({"path": shorten(p), "exists": True, "parent": parent, "plainChild": child})
        self.report["checks"]["tccInheritance"] = {
            "probes": rows,
            "parentProcess": os.path.basename(subprocess.run(["/bin/ps", "-o", "comm=", "-p", str(os.getppid())],
                                                             capture_output=True, text=True).stdout.strip()),
            "meaning": "Only shows whether a plain child of THIS process sees what its parent sees. It does not show "
                       "what a child of Lintel.app sees; see README, 'TCC inheritance'.",
        }
        self.report["notVerified"].append("TCC: a child of Lintel.app with Full Disk Access (needs the owner, README).")

    # -- disk
    def disk(self):
        if self.args.no_calls:
            return
        roots = scan_roots(os.environ, [self.work], self.child_tmp)
        hits, counts = scan_for_markers(roots, list(self.markers.values()), self.since)
        names = {v: k for k, v in self.markers.items()}
        per_call = {names[m]: [shorten(p) for p in paths] for m, paths in hits.items()}
        cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
        isolated = sorted(n for n in self.markers if n != "control" and not n.startswith("userConfig-"))
        sessions = {n: len(session_files_with_marker(cfg, self.markers[n])) for n in isolated}
        cleaned = []
        if self.args.cleanup_control and self.args.positive_control_real_config:
            cfg_projects = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "projects")
            for p in hits.get(self.markers.get("control", ""), []):
                if p.startswith(cfg_projects + os.sep) and p.endswith(".jsonl"):
                    try:
                        os.remove(p)
                        cleaned.append(shorten(p))
                        d = os.path.dirname(p)
                        if not os.listdir(d):
                            os.rmdir(d)
                    except OSError:
                        pass
        counts["truncatedRoots"] = [shorten(r) for r in counts["truncatedRoots"]]
        emptied = self.remove_own_empty_project_dirs(cfg) if self.args.positive_control_real_config else 0
        self.report["checks"]["diskCopies"] = {
            "rootsScanned": [shorten(r) for r in roots], **counts,
            "pathsContainingMarkerByCall": {k: v for k, v in per_call.items() if v},
            "callsWithAnyCopy": sorted(k for k, v in per_call.items() if v),
            "isolatedCallsWithCopy": sorted(k for k, v in per_call.items() if v and k in isolated),
            "isolatedCallsChecked": len(isolated),
            "sessionFilesWithMarkerByIsolatedCall": sessions,
            "noSessionFileFromIsolatedCalls": not any(sessions.values()),
            "controlSessionFilesRemoved": cleaned, "ownEmptyProjectDirsRemoved": emptied,
            "ownProjectDirsLeftInConfig": len(self.own_project_dirs(cfg)),
            "note": "Only the marker is searched for; paths and counts are reported, never file content. The proof "
                    "that the search can find a session file is userConfig.control (temporary HOME) and, with "
                    "--positive-control-real-config, the control call.",
        }

    def own_project_dirs(self, cfg):
        """Directories under `<config>/projects` named after THIS run's temporary directory."""
        base, tag = os.path.join(cfg, "projects"), os.path.basename(self.work)
        try:
            return sorted(os.path.join(base, n) for n in os.listdir(base) if tag in n)
        except OSError:
            return []

    def remove_own_empty_project_dirs(self, cfg):
        """Removes this run's project directories from the config directory when they hold no file at all."""
        removed = 0
        for d in self.own_project_dirs(cfg):
            if any(files for _r, _d, files in os.walk(d)):
                continue
            for root, _dirs, _files in os.walk(d, topdown=False):
                try:
                    os.rmdir(root)
                except OSError:
                    pass
            removed += not os.path.exists(d)
        return removed

    def run(self):
        self.locator()
        self.env_allowlist()
        if self.args.no_calls:
            self.tcc()
            return self.report
        steps = [("auth", self.auth), ("timings", self.timings), ("userConfig", self.user_config),
                 ("isolation", self.isolation), ("hooks", self.hook_events),
                 ("truncation", self.truncation), ("failures", self.failures), ("tcc", self.tcc), ("disk", self.disk)]
        only = set(self.args.only.split(",")) if self.args.only else None
        for name, step in steps:
            if only is None or name in only:
                step()
        return self.report

    def close(self):
        if not self.args.keep_workdir:
            shutil.rmtree(self.work, ignore_errors=True)


def find_claude(explicit):
    if explicit:
        return explicit
    for d in ("~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"):
        p = os.path.join(os.path.expanduser(d), "claude")
        if os.path.exists(p):
            return p
    return None


def summarize(report):
    c = report.get("checks", {})
    lines = ["CLI: %s" % json.dumps({k: report.get("cli", {}).get(k) for k in ("version", "nativeMachO", "isSymlink", "ownerIsUserOrRoot")})]
    for name in ("coldTiny", "input3kPl", "input3kEn", "inputLargePl"):
        if name in c:
            e = c[name]
            lines.append("%-13s exit=%s %ss in=%s (estimator %s, ratio %s) out=%s api_ms=%s" % (
                name, e.get("exit"), e.get("seconds"), e.get("input_tokens_total"), e.get("estimatorTokens"),
                e.get("reportedOverEstimator"), e.get("output_tokens"), e.get("duration_api_ms")))
    iso = c.get("isolation")
    if iso:
        lines.append("isolation: filesBlocked=%s shellBlocked=%s hookNotRun=%s claudeMdNotLoaded=%s mcpNotLaunched=%s tools=%s" % (
            iso["tools1FileReadBlocked"], iso["tool2ShellBlocked"], iso["hook3NotRun"], iso["claudeMd4NotLoaded"],
            iso["mcp4NotLaunched"], iso.get("init", {}).get("toolNames")))
    uc = c.get("userConfig")
    if uc:
        lines.append("userConfig (temporary HOME): controlIsSensitive=%s productLoadsNoUserConfig=%s "
                     "productLeavesNoSessionFile=%s" % (uc["controlIsSensitive"], uc["productLoadsNoUserConfig"],
                                                        uc["productLeavesNoSessionFile"]))
        for name in ("control", "product", "settingSourcesOnly", "strictMcpOnly", "safeModeOnly", "noSessionPersistenceOnly"):
            e = uc[name]
            lines.append("  %-25s hooks=%s mcp=%s pluginHook=%s sessionFiles=%s modelCall=%s" % (
                name, e["userHooksFired"], e["mcpLaunched"], e["pluginHookFired"], e["sessionFilesWithMarker"],
                e["modelCallMade"]))
    he = c.get("hookEvents")
    if uc:
        lines.append("  --version / auth status ran nothing of the user config: %s" % uc["noContentCommands"]["nothingRan"])
    if he:
        lines.append("hookEvents (real login, product flags): detectorWorks=%s hooksStartedBeyondCanary=%s modules=%s" % (
            he["detectorWorks"], he["hooksStartedBeyondCanary"], he["hookModulesByTier"]))
    if "control" in c:
        lines.append("control: %s" % (c["control"].get("marks") or "skipped (opt-in)"))
    if "diskCopies" in c:
        d = c["diskCopies"]
        lines.append("disk: callsWithAnyCopy=%s isolatedCallsWithCopy=%s of %s sessionFiles=%s filesChanged=%s read=%s truncatedRoots=%s" % (
            d["callsWithAnyCopy"], d["isolatedCallsWithCopy"], d["isolatedCallsChecked"],
            d["sessionFilesWithMarkerByIsolatedCall"], d["filesChangedSince"], d["filesRead"], d["truncatedRoots"]))
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--claude", help="path of the claude binary (default: the locator list of the spec)")
    ap.add_argument("--out", help="write the JSON report here (default: stdout)")
    ap.add_argument("--model", default="sonnet", help="model for the timing calls")
    ap.add_argument("--cheap-model", default="haiku", help="model for the isolation, failure and truncation calls")
    ap.add_argument("--medium-tokens", type=int, default=3000)
    ap.add_argument("--large-tokens", type=int, default=40000, help="estimator tokens of the one large call (Q12: 40000)")
    ap.add_argument("--skip-large", action="store_true")
    ap.add_argument("--no-calls", action="store_true", help="offline checks only (locator, env, TCC probe); no model call")
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--cancel-after", type=float, default=1.5)
    ap.add_argument("--only", help="comma list of steps: auth,timings,userConfig,isolation,hooks,truncation,failures,tcc,disk")
    ap.add_argument("--positive-control-real-config", action="store_true",
                    help="OFF by default. Also run the controls that load your REAL settings: your own hooks run")
    ap.add_argument("--merge-into", help="existing report JSON whose checks are updated by this run")
    ap.add_argument("--keep-workdir", action="store_true")
    ap.add_argument("--no-cleanup-control", dest="cleanup_control", action="store_false")
    args = ap.parse_args(argv)
    args.claude = find_claude(args.claude)
    if not args.claude or not os.path.exists(args.claude):
        print("claude binary not found; pass --claude", file=sys.stderr)
        return 2
    if args.positive_control_real_config:
        print(REAL_CONFIG_WARNING, file=sys.stderr)
    canary = None
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))  # so that the work directory is removed on SIGTERM too
    try:
        canary = Canary(args)
        report = canary.run()
    finally:
        if canary is not None:
            canary.close()
    if args.merge_into:
        with open(args.merge_into) as f:
            base = json.load(f)
        base.setdefault("checks", {}).update(report.get("checks", {}))
        base["notVerified"] = sorted(set(base.get("notVerified", [])) | set(report.get("notVerified", [])))
        report = base
    text = json.dumps(report, indent=2, sort_keys=True)
    for marker in canary.markers.values():
        assert marker not in text, "marker leaked into the report"
    if args.out:
        with open(args.out, "w") as f:
            f.write(text + "\n")
    else:
        print(text)
    print(summarize(report), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
