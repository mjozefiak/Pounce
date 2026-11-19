# ADR 0011: External AI providers for meeting notes (Claude Code CLI first, API key second)

- Status: **Accepted** for the decisions below (owner decisions of 2026-11-19, recorded in
  `.ai/specs/2026-11-10-external-ai-providers.md`). **`isolationVerified` stays `false`** in the descriptor. The
  user-level isolation below is measured, but canary point 5 (TCC inheritance for a child of Lintel) and the other
  items of "What is not verified" are open, and setting the flag to `true` is the owner's decision, not this ADR's.
- Date: 2026-11-19
- Spec: `.ai/specs/2026-11-10-external-ai-providers.md` (story MEET-X.1), PR 1 of its plan (canary, measurements,
  this ADR). This PR changes no behaviour and no screen of the app.
- Number 0011: 0010 is the dictation-context ADR on `main`; no open pull request adds an ADR (checked 2026-11-19).
  This resolves spec question Q10.
- Canary: `scripts/provider-canary/` (manual, nothing calls it). Claude Code 2.1.328, macOS 27.0.1, Apple M4 Max,
  128 GB, subscription login (`claude.ai`), run 2026-11-19. All input was synthetic.

## Context

Notes written by the built-in model are weaker than Claude's, and slow on a smaller Mac. The owner asked for
optional providers, off by default. A provider means meeting transcripts leave the Mac, which Lintel has so far
promised never to do. This ADR records the decisions that make that acceptable and the measurements that show the
Claude Code CLI can be run in the way the decisions require.

## Decisions

1. **Phase 1 is the Claude Code CLI on the user's own subscription, as a child process.** Lintel never reads or
   stores the CLI's credentials. Phase 2 (right after) adds a bring-your-own API key as a second channel to the
   same recipient, with the same consent gate. No other provider in v1 (Codex, Gemini and Grok are Phase 3, each
   with its own canary and consent).
2. **One consent, at the moment the provider and model are chosen in Settings.** After it, every meeting goes to
   the provider until the user returns to the built-in model. There is no per-meeting flag, no "every new
   meeting" switch and no "participants know" confirmation. The text for participants is unchanged. The consent
   names the provider and the model, lists speaker names and segment times among what leaves the Mac, and says
   that automatic re-runs and "Regenerate Notes" on older meetings also send.
3. **Enforced in code before every content-carrying process.** `ProviderRunner.run` is the only entry for a
   process that carries user data (and, in Phase 2, for a network request). It asks the consumer's authorization
   closure directly before each `Process.run()`, after the queue. A denial ends the job with no process. A change
   of provider or model needs a new consent; a version bump of the consent text invalidates the stored one. The
   test matrix "0 processes without consent" is a merge condition of the PR that connects the provider.
4. **Processes without content** (`--version`, `claude auth status`, "Try it" with a fixed text) need no consent
   but start only from an action in the panel of an active plugin, never from `settingsPane()` or a status getter.
5. **One-generation track for the provider (owner, 2026-11-19, overturns the quote-chunk track for providers).**
   The provider gets the whole transcript in one call, writes the notes itself with a new versioned prompt, and
   code checks the facts against the whole transcript. The built-in model stays on the quote track. The track is
   built and measured on synthetic data before the provider is connected.
6. **Quality gate G** blocks the consent UI, the migration and the connection of the provider until one
   measurement of the whole-transcript generator with Claude (development harness, synthetic corpus only, not the
   4B model) passes. One measurement, not weeks of conditions. Thresholds (80 percent, 0 false sentences) stay
   working values.
7. **Marker on the meeting, not on blocks.** "Sent to: Claude · model" in the app only (library row, meeting
   window, Notes details). No AI marks per block, no provider name in exports or copies. The marker describes the
   notes now stored; partial sends leave no trace (accepted limitation, Q11).
8. **Descriptor flag `isolationVerified`.** `ProviderRunner` refuses to start a process for a descriptor whose
   flag is `false`. It is set in code only from the canary result in this ADR.
9. **The provider process never runs the user's hooks and never loads the user's settings, MCP servers or
   plugins: user level, not only project level (owner requirement, 2026-11-19).** The mechanism is the argv, because
   an isolated configuration directory loses the subscription login (measured below). Required in every
   content-carrying call, and tested in the PR that adds `ProviderProcess`:
   - `--setting-sources ""` (no user, project or local settings: no hooks, no enabled plugins, no user MCP servers),
   - `--strict-mcp-config` with no `--mcp-config` (a second, independent switch for MCP servers),
   - `--no-session-persistence` (no session file with the transcript),
   - `--tools ""` and `--disable-slash-commands`,
   - never `--settings`, `--mcp-config`, `--plugin-dir`, `--plugin-url`, `--add-dir`, `--agents`, `--continue` or
     `--resume`,
   - the environment is the allowlist only (no `CLAUDE_*` or `ANTHROPIC_*` variable other than
     `CLAUDE_CONFIG_DIR` and the authentication variables passes), and the working directory is a new empty
     directory (so there is no project configuration to find).
   A call that lacks one of the flags is a release blocker, not a degraded mode.

## Canary results

Method: `scripts/provider-canary/canary.py`; the environment allowlist of the spec plus `USER`; working directory an
empty temporary directory (a decoy project for the isolation probes); private `TMPDIR`. Counts and paths only; no
content was recorded. Two measurements on 2026-11-19 with the same CLI version: the first run (timings, project
level isolation, failures) and a second one for the user level (`--only userConfig,isolation,hooks,disk`; 5 short
logged-in Haiku calls in total, the rest without a login and so without a model call).

### What the first run did to the owner's real configuration (corrected)

The first version of the script ran, on every full run, two calls with the owner's real `HOME` and **without**
`--setting-sources ""`: the positive control `control` (`--setting-sources project`, tools allowed, session
saved) and `hookModules.withoutTheFlag` (no source flag at all). The second one loaded the owner's whole user
configuration, so **the owner's real hooks ran in it** (the owner has command hooks on session start, prompt submit
and stop), and both left a project directory in the owner's real config directory (two empty
`projects/*provider-canary-*` directories are still there; the session file of the control was removed by the
script). The author's report spoke of about 14 calls: a full run made about 14 model calls, of which these two
lacked the flag; the other calls carried `--setting-sources ""`, and the second measurement shows that with it no
user hook starts. How many full or partial runs the author made is not recorded, so the exact number of calls that
ran real hooks is unknown; from the code it is one or two per run, not every call. This was a defect of the
script, not a finding about the CLI. Now both calls exist only behind `--positive-control-real-config` (off by
default, with a warning), every call with the real `HOME` is refused unless it carries the isolation flags, and
the sensitive control runs in a temporary `HOME`.

### User-level isolation (owner requirement; measured 2026-11-19)

Set-up: a temporary `HOME` with a synthetic user configuration: command hooks for SessionStart, UserPromptSubmit,
Stop and SessionEnd in `~/.claude/settings.json`, a user-scope MCP server in `~/.claude.json`, an installed and
enabled plugin with a SessionStart hook, and an agent definition. Each of them creates an empty marker file when the
CLI runs it. The CLI is not logged in there (see "Isolated configuration directory"), so each call stops at "Not
logged in" after start-up: no model call.

| Case (temporary `HOME`) | User hooks that ran | User MCP server | Plugin loaded / its hook | Session file with the marker |
|---|---|---|---|---|
| `control`: no isolation flag | SessionStart, UserPromptSubmit, SessionEnd | started | loaded / ran | 1 |
| **`product`: the flags of decision 9** | **none** | **not started** | **not loaded / not run** | **0** |
| `--setting-sources ""` alone | none | not started | not loaded / not run | 1 |
| `--strict-mcp-config` alone | SessionStart, UserPromptSubmit, SessionEnd | not started | loaded / ran | 1 |
| `--safe-mode` alone | none | not started | listed / not run | 1 |
| `--no-session-persistence` alone | SessionStart, UserPromptSubmit, SessionEnd | started | loaded / ran | 0 |

- The control proves the test is sensitive: the same hooks, server and plugin do run when the flags are absent.
- `--setting-sources ""` is the flag that turns off user hooks, user plugins and the user-scope MCP server;
  `--strict-mcp-config` turns off MCP servers on its own; `--no-session-persistence` is the only flag that stops
  the session file. The product needs all three.
- In the `product` case the init event reports 0 tools, 0 MCP servers, 0 skills, 0 slash commands, 4 plugins (all
  built into the CLI: `cc-plugin-agents-md`, `cc-plugin-plugin-authoring`, `cc-plugin-privacy`,
  `cc-plugin-telemetry`) and 5 agents; the synthetic agent is not listed. The stream reports 0 started hooks.
- The processes without content, `claude --version` and `claude auth status`, ran against the same synthetic user
  configuration without any flag and created no marker: they run no user hook, MCP server or plugin hook.
- **Under the real login** (the owner's real `HOME`, the product flags, one call): a canary hook passed by
  `--settings` for UserPromptSubmit and Stop fired (so hook events are reported and the Stop stage is reached), and
  it was the only hook that started: `hooksStartedBeyondCanary` = 0, although the owner's own configuration has
  hooks for the same events. The debug log shows 0 user-tier and 4 built-in hook modules. The isolation call (decoy
  project) reported 0 started hooks, 0 MCP servers and 0 tools in each of 4 runs.
- **Session files under the real login:** 0 `.jsonl` files with the marker in the real config directory's
  `projects/` for every isolated call, and no project directory was created there for this run.
- One observation is not explained: the init event of one of the 4 isolation calls listed 5 plugins instead of 4.
  The name was not recorded in that run; no hook started and no MCP server was listed in that call, and the next
  three calls listed the 4 built-in ones (0 not built in). The script now records how many plugins are not built in.

### Isolated configuration directory (measured; not usable with a subscription)

`claude auth status` under the allowlist: `loggedIn: true` with the real `HOME`; `loggedIn: false` with a temporary
`HOME`, with a temporary `CLAUDE_CONFIG_DIR` (real `HOME`), and with a temporary `HOME` plus `CFFIXED_USER_HOME`.
The login is tied to the user's own configuration directory, so a separate directory needs its own login or a copy
of the credentials. Lintel does neither (decision 1: it never reads or stores the CLI's credentials), and the
canary did not copy any credential. So the product passes the real `HOME` (and `CLAUDE_CONFIG_DIR` when set) and
relies on the flags of decision 9. If the owner wants the stronger variant (a Lintel-owned config directory with
its own `claude` login), that is a product decision with its own consent text: see "What is not verified", 6.

### Flags (golden list for the descriptor)

`claude -p --model <m> --output-format json --tools "" --no-session-persistence --disable-slash-commands
--strict-mcp-config --setting-sources "" --system-prompt <static text>`, content on stdin. All of them exist and
work in 2.1.328 (every logged-in canary call of the default run uses them). Notes:

- `--bare` stays unusable with a subscription (it reads only `ANTHROPIC_API_KEY`); it is the candidate for Phase 2.
- `--safe-mode` exists in this version ("all customizations disabled", auth and built-in tools still work). Alone,
  in the temporary `HOME`, it stopped the user hooks, the MCP server and the plugin hook (table above). It was not
  measured together with the product flags or with a login, so it is not in the golden list; it is the candidate
  for a second layer if the owner wants one. Its help text says admin-managed settings and the hooks of managed
  plugins still apply.
- `--restricted` (ignores user, project and local settings files, removes code-running tools) also exists; not
  measured.
- The aliases `sonnet` and `haiku` are accepted by `--model`.
- stdin works for a prompt of at least 56 000 tokens (below).
- The binary is a native Mach-O arm64 file (`~/.local/bin/claude` is a symbolic link into
  `~/.local/share/claude/versions/<version>`), owned by the user, not group or world writable. It does not need
  `node` on `PATH`, so the fixed `PATH` `/usr/bin:/bin:/usr/sbin:/sbin` is enough. An npm install (needs `node`)
  was not tested; the spec's default (support it only through "Choose file…") stands.

### Spec table

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | File tools | **Pass.** With `--tools ""` the model could not read a file outside the working directory; the answer did not hold the file's token. | Init event: `tools` is empty. First run: the positive control (tools allowed) did read it. |
| 2 | Shell | **Pass.** The marker file was not created. | First run: the control created it. |
| 3 | Hooks | **Pass, project and user level.** The decoy project hook did not run. A user-level command hook runs without the flags and does not run with them (section "User-level isolation"); under the real login no hook of the owner started. In the debug log the CLI loads 2 user-level hook modules without `--setting-sources ""` (first run) and 0 with it (4 built-in modules in both). | First run: the control ran the project hook. Second run: the temporary-`HOME` control ran the user hooks. |
| 4 | `CLAUDE.md`, MCP, plugins | **Pass**, with one unexplained observation (above). The project token was not in the answer, the decoy MCP server was not launched; init reports 0 MCP servers, 0 skills, 0 slash commands, 4 built-in plugins and 6 agents (5 in the temporary `HOME`; the extra one under the login was not identified, agents are definitions and `--tools ""` leaves no tool to start one). A user-scope MCP server and a user plugin do not load with the flags. | First run: the control answered the token and launched the MCP server. Second run: the temporary-`HOME` control started the user MCP server and loaded the plugin. |
| 5 | TCC inheritance | **Not verified.** See below. | |
| 6 | Copies on disk | **Pass.** First run: 0 files with a canary from the 5 isolated calls among 168 files modified in the scanned roots (CLI config directory, home caches and logs, system temp, working and temp directories). The control call, run without `--no-session-persistence`, left the transcript and answer in `~/.claude/projects/<encoded working directory>/<uuid>.jsonl` (1 file): this confirms the spec's assumption and proves the scan can find a copy. The script removed that file. Second run: in the temporary `HOME`, 1 session file with the marker without the flag and 0 with it; 0 session files and 0 other copies from the isolated logged-in calls (about 100 changed files scanned). | The scan stopped at 400 000 entries in `~/.cache`. |
| 7 | Login | **Pass.** `auth status` ready (`loggedIn`, `claude.ai`, `firstParty`); calls work. | |

### Behaviour the spec did not assume (the spec is corrected in this PR)

- **`USER` must be in the environment allowlist.** Without it `claude auth status` says `loggedIn: false` and
  `claude -p` answers "Not logged in" although the login exists. `LOGNAME` is not needed.
- **Errors are mostly on stdout, as JSON, with exit code 1 and an empty stderr.** Not logged in, an unknown model
  and a truncated answer all give exit 1, `is_error: true` and the reason in `result`. Only an unknown flag writes
  to stderr (`error: unknown option ...`, exit 1). `classify` must therefore read the stdout JSON as well as
  stderr, and a result with `is_error` is a failure whatever its text.
- **Truncation is detectable.** An answer cut by the output limit is exit 1, `is_error: true` and a `result` that
  begins "API Error: Claude's response exceeded the N output token maximum". `stop_reason` is `stop_sequence` and
  `subtype` is `success` in that case, so neither can be used. The spec's fallback (judge by the shape of the last
  line) is kept as a second guard.
- **SIGTERM works.** Sent to the process group 1.5 s into a long generation, the CLI exited with code 143 after
  0.69 s and left no process in the group. The 2 s grace then SIGKILL of the spec is enough.
- **Fixed overhead per call: about 810 input tokens** (the tiny call reports 812) with `--tools ""` and a one-line
  system prompt.
- **Token estimator.** The app's estimator (words times 2.69 for Polish, 1.17 for English) undercounts what the
  provider reports on the synthetic text, which has a `[mm:ss] Name:` prefix on every line: reported over estimator
  1.34 (Polish 3 000, after the 812 fixed tokens), 1.39 (Polish 40 000) and 1.82 (English 3 000). The synthetic
  vocabulary is small and repetitive, so these are indications, not constants. A 100 000 token budget by the
  estimator is therefore about 134 000 to 182 000 real tokens.

### Timings (Sonnet, `--output-format json`, short answers of 212 to 450 output tokens)

| Case | Input tokens reported | Wall time | API time |
|---|---|---|---|
| Tiny prompt, first call of the run ("cold") | 812 | 3.76 s | 2.31 s |
| About 3 000 estimator tokens, Polish | 4 834 | 4.57 s | 3.53 s |
| About 3 000 estimator tokens, English | 6 288 | 3.99 s | 2.92 s |
| About 40 000 estimator tokens, Polish (Q12 part size) | 56 408 | 6.02 s | 4.93 s |

Wall time minus API time is about 1 to 1.4 s (process start and login). The first call is not slower than the
others by more than the noise of one run each. Real notes are longer than these answers (about 1 500 tokens of
output), so the times are a lower bound for `ProviderNotesGenerator`; the working limit of 600 s per call has a very
large margin. Not measured: the 100 000 token budget, a one-hour and a three-hour transcript, and the largest input
the CLI accepts (`canary.py --large-tokens 100000 --only timings`; see `docs/perf.md`).

## What is not verified

1. **TCC (canary point 5).** The canary opens two protected files from itself and from a plain child. On this Mac
   the terminal that ran it has no Full Disk Access, so both failed with errno 1 and nothing about inheritance was
   learned. Whether a child of `Lintel.app` holding Full Disk Access, Accessibility or the microphone can use those
   permissions was not tested. **Owner action:** the procedure is in `scripts/provider-canary/README.md` ("TCC
   inheritance"). Until it is done the working assumption is that a child does inherit Lintel's permissions, and the
   protection is option (a) of the spec: tools and hooks shown to be off. Option (b), disclaiming responsibility at
   spawn, needs private API and a separate owner decision.
2. **User-level hooks, MCP servers and plugins: measured (section "User-level isolation"), with these limits.**
   (a) The sensitive control and the flag-by-flag cases ran without a login, so they cover start-up, prompt submit
   and session end; the Stop stage and the whole logged-in turn are covered only by the one real-login call (a
   `--settings` canary hook fired, nothing else started). A user-level hook was never made to fire *under a login*,
   because that needs the owner's real configuration or a copied credential. (b) One call listed a fifth plugin
   that was not identified. (c) Admin-managed (policy) settings and managed plugins are outside
   `--setting-sources` by design of the CLI; this Mac has none (`/Library/Application Support/ClaudeCode` does not
   exist) and nothing was measured. (d) The user's own `~/.claude/CLAUDE.md` and auto-memory under the real login
   were not probed (the project `CLAUDE.md` was; with `--system-prompt` and no tools they could only add text to
   the request, not start a process). Residual risk: a future CLI version moves a source outside the flag.
   Mitigation: `isolationVerified` is tied to a version range, the canary is repeated for every new range
   (`--only userConfig,isolation,hooks,disk`: 2 short model calls), and `--safe-mode` is the candidate second
   layer. **Owner action (optional, closes (a)):** `canary.py --only isolation,hooks,disk
   --positive-control-real-config` runs your real hooks once on purpose and shows that they do fire without the
   flags on your own configuration; read the warning in the README first.
3. Another account's login and other install methods (npm, Homebrew) were not tested.
4. A real hour of meeting: all input was synthetic; no real transcript or speaker name was sent.
5. The disk scan is bounded (400 000 entries per root; `~/.cache` was cut). A copy outside the scanned roots would
   not be seen.
6. **A Lintel-owned configuration directory with its own login** (the stronger isolation: nothing of the user's
   configuration is even readable by the CLI). Not tested: it needs an interactive `claude` login into that
   directory by the owner, or a copy of the credentials, which the canary must not make. **Owner procedure:**
   `CLAUDE_CONFIG_DIR=<empty directory> claude` and log in there, then
   `CLAUDE_CONFIG_DIR=<that directory> python3 scripts/provider-canary/canary.py --only auth,isolation,hooks,disk`;
   `loginState.authStatus.loggedIn` must be `true`. Then decide whether the product should ask users for a second
   login; today's decision is that it does not.
7. The 100 000 token budget, a one-hour and a three-hour transcript and the largest accepted input (see Timings).

## Risks accepted (owner, 2026-11-10 and 2026-11-19)

- Terms of service: whether a free open-source app calling `claude -p` counts as "running Claude Code in your
  products" is unsettled. Conditions: unmodified binary, no handling of credentials or sessions, no filtering of
  authentication methods, provider name as plain text only, the UI says it is the user's subscription and CLI.
- Lintel does not tell participants that a cloud provider processes the meeting; the consent tells the user.
- One consent covers all meetings, including confidential ones, until the user switches back.
- The marker does not record partial or failed sends.
- The CLI changes weekly: argv lives in one pure function with golden tests, the version range is checked, the
  canary is repeated per range.
- An authentication variable in Lintel's environment (for example `ANTHROPIC_API_KEY`) is passed through, and the
  CLI may then bill per token. The panel warns about it.

## Consequences

- PR 2 builds `LintelProviders` against this list of flags, with `isolationVerified = false`, and ships the tests
  of decision 9: the golden argv holds every required flag with an empty value where one is required and none of
  the forbidden ones; the environment handed to the process is exactly the allowlist; the working directory is new
  and empty; a descriptor whose argv lacks a required flag is refused before `Process.run()`.
- The spec is corrected where the canary disagreed (allowlist, error reporting, truncation, confirmed session files).
- `docs/perf.md` has the measured rows and the rows still "not yet measured".
- The built-in model path and every existing setting are unchanged.
