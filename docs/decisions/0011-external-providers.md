# ADR 0011: External AI providers for meeting notes (Claude Code CLI first, API key second)

- Status: **Accepted** for the decisions below (owner decisions of 2026-11-19, recorded in
  `.ai/specs/2026-11-10-external-ai-providers.md`). **`isolationVerified` stays `false`** in the descriptor until the
  code and tests of PR 2 exist. **The flag does not depend on the TCC test (owner, 2026-11-20).** It rests on the
  measured isolation (no tools, hooks, MCP servers, plugins or session files from the user's configuration, for a
  CLI version range) and on the tests of decision 9. TCC/FDA has its own row in "Spec table" and in "What is not
  verified" and is checked after the first signed install. Setting the flag to `true` stays the owner's decision.
- Date: 2026-11-19. Follow-up measurements of 2026-11-20 (Claude Code 2.1.329): see "Follow-up of 2026-11-20".
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
   same recipient, with the same gate (the chosen provider; see the amendment of 2026-11-20). No other provider in v1
   (Codex, Gemini and Grok are Phase 3, each with its own canary; whether choosing a new company asks anything is
   open, see the amendment).
2. **One consent, at the moment the provider and model are chosen in Settings.** *(Superseded 2026-11-20: the
   choice of the provider is the consent, with a fixed short notice and a "Details" link instead of a window; see
   the amendment. The original text follows.)* After it, every meeting goes to
   the provider until the user returns to the built-in model. There is no per-meeting flag, no "every new
   meeting" switch and no "participants know" confirmation. The text for participants is unchanged. The consent
   names the provider and the model, lists speaker names and segment times among what leaves the Mac, and says
   that automatic re-runs and "Regenerate Notes" on older meetings also send.
3. **Enforced in code before every content-carrying process.** `ProviderRunner.run` is the only entry for a
   process that carries user data (and, in Phase 2, for a network request). It asks the consumer's authorization
   closure directly before each `Process.run()`, after the queue. A denial ends the job with no process. A change
   of provider or model needs a new consent; a version bump of the consent text invalidates the stored one. *(Superseded
   2026-11-20: a change of model at the same provider asks nothing; there is no consent text version; the request's
   provider and model are compared with the setting read at that moment. The original sentence is kept for the
   record.)* The test matrix "0 processes without a chosen provider" (formerly "without consent") is a merge
   condition of the PR that connects the provider.
4. **Processes without content** (`--version`, `claude auth status`, "Try it" with a fixed text) need no consent
   but start only from an action in the panel of an active plugin, never from `settingsPane()` or a status getter.
5. **One-generation track for the provider (owner, 2026-11-19, overturns the quote-chunk track for providers).**
   The provider gets the whole transcript in one call, writes the notes itself with a new versioned prompt, and
   code checks the facts against the whole transcript. The built-in model stays on the quote track. The track is
   built and measured on synthetic data before the provider is connected.
6. **Quality gate G** blocks the provider-choice UI (formerly "consent UI"), the migration and the connection of the provider until one
   measurement of the whole-transcript generator with Claude (development harness, synthetic corpus only, not the
   4B model) passes. One measurement, not weeks of conditions. Thresholds (80 percent, 0 false sentences) stay
   working values.
7. **Marker on the meeting, not on blocks.** "Sent to: Claude · model" in the app only (library row, meeting
   window, Notes details). No AI marks per block, no provider name in exports or copies. The marker describes the
   notes now stored; there is no send log in v1 (no table or file of past sends), so partial sends leave no
   trace (accepted limitation, Q11).
8. **Descriptor flag `isolationVerified`.** `ProviderRunner` refuses to start a process for a descriptor whose
   flag is `false`. It is set in code only from the canary result in this ADR. **Owner condition, 2026-11-20: the
   flag is never switched on its own; only in the pull request with the Settings UI for choosing the provider and
   after a measurement on the real CLI with synthetic data. A pull request that changes only that line, or its
   pinned test, is refused** (amendment, decision 4).
9. **The provider process never runs the user's hooks and never loads the user's settings, MCP servers or
   plugins: user level, not only project level (owner requirement, 2026-11-19).** The mechanism is the argv, because
   an isolated configuration directory loses the subscription login (measured below). Required in every
   content-carrying call, and tested in the PR that adds `ProviderProcess`:
   - `--setting-sources ""` (no user, project or local settings: no hooks, no enabled plugins, no user MCP servers),
   - `--strict-mcp-config` with no `--mcp-config` (a second, independent switch for MCP servers),
   - `--no-session-persistence` (no session file with the transcript),
   - `--tools ""` and `--disable-slash-commands`,
   - `--safe-mode` (added 2026-11-20 after the measurement in "Follow-up of 2026-11-20": it changes neither the
     login nor the result format and removes one agent definition (source not identified) and one memory path that
     the flags alone leave in the request),
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
--strict-mcp-config --setting-sources "" --safe-mode --system-prompt <static text>`, content on stdin. All of them exist and
work in 2.1.329 (every logged-in canary call of the default run uses all of them except `--safe-mode`, which the
`safeMode` step adds to compare; the other flags were also used in 2.1.328). Notes:

- `--bare` stays unusable with a subscription (it reads only `ANTHROPIC_API_KEY`); it is the candidate for Phase 2.
- `--safe-mode` ("all customizations disabled", auth and built-in tools still work): measured alone in the first
  run (temporary `HOME`) and, on 2026-11-20, together with the product flags under the real login. It is in the
  golden list. Its help text says admin-managed settings and the hooks of managed plugins still apply (this Mac has
  none). A CLI version without the flag fails with an unknown-option error (exit 1, `incompatibleVersion`).
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
| 5 | TCC inheritance | **Not verified; does not gate `isolationVerified`.** See below. | |
| 5b | **TCC/FDA** | **To be checked after the first signed install.** | Owner action; procedure in `scripts/provider-canary/README.md`. |
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

## Follow-up of 2026-11-20 (Claude Code 2.1.329, macOS 27.0.1, subscription login)

Script: `scripts/provider-canary/canary.py`, steps `safeMode` and `realConfig`. All prompts were synthetic text with a
random marker. The report holds counts only; no hook name, setting, path or file content of the owner was read or is
recorded here.

### `--safe-mode` (flag exists in 2.1.329; measured with the real login)

Two runs of four short Haiku calls each: the product flags alone, and the product flags plus `--safe-mode`, each
once with `--output-format json` (login and result shape) and once with `stream-json` (the init event and the hook
events). Both runs gave the same numbers.

| | Product flags | Product flags + `--safe-mode` |
|---|---|---|
| Exit code, `is_error`, answer present | 0, false, yes | 0, false, yes |
| Keys of the JSON result, `subtype`, stderr | same set, `success`, empty | same set, `success`, empty |
| Hooks started, user-tier hook modules | 0, 0 | 0, 0 |
| Tools, MCP servers, skills, slash commands | 0, 0, 0, 0 | 0, 0, 0, 0 |
| Plugins (not built in) | 4 (0) | 4 (0) |
| **Agents listed** | **6** | **5** |
| **Memory paths listed** | **1** | **0** |

Result: **both conditions hold.** The subscription login and the output format are unchanged, and the isolation is
stronger: the flags alone still let one agent definition and one memory path reach the request (they are definitions
and text, not processes; `--tools ""` leaves nothing to start an agent), and `--safe-mode` removes both. The sixth
agent is the one the first measurement could not identify; its source was not identified further. `--safe-mode` is
therefore in decision 9 and in the golden list. It is a second layer, not a replacement: the flags of decision 9
stay, because in the temporary `HOME` table `--safe-mode` alone did not stop the session file.

### Positive control with the owner's real configuration (one run, owner's consent)

One pair of calls with the real `HOME`, behind `--positive-control-real-config` (off by default): the same synthetic
probe without the configuration flags and with the product flags. Both calls kept `--no-session-persistence` and
`--tools ""`. Counts from the init event, the hook events and the debug log:

| | Without the flags | With the flags |
|---|---|---|
| Hooks started (SessionStart / UserPromptSubmit / Stop) | **4** (2 / 1 / 1) | **0** |
| User-tier hook modules in the debug log | 2 | 0 |
| MCP servers | 11 | 0 |
| Plugins (not built in) | 8 (4) | 4 (0) |
| Skills | 154 | 0 |
| Slash commands | 199 | 0 |
| Tools in the init event | 198 | 0 |
| Agents | 6 | 6 |
| Model call worked | yes | yes |

- The control is informative: the owner's hooks, servers, plugins, skills and commands do load and run without the
  flags, and nothing of them loads with them. This closes item 2(a) of "What is not verified".
- **`--tools ""` removes only the built-in tools.** With the user's 11 MCP servers loaded the init event listed 198
  tools. `--strict-mcp-config` and `--setting-sources ""` are what remove them, so they are not optional.
- Changes in the config directory (by name and time, no content read): 0 new files, 3 new empty directories (two
  under `projects/`, one of them a `memory` subdirectory, and one under `session-env/`), 3 existing CLI state files
  modified, and `~/.claude.json` modified. No session file was written. Which of the two calls created the
  directories was not recorded. The script deletes nothing; the three empty directories are for the owner to remove.

## What is not verified

1. **TCC/FDA: to be checked after the first signed install (canary point 5; not a condition of `isolationVerified`).** The canary opens two protected files from itself and from a plain child. On this Mac
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
   (`--only userConfig,isolation,hooks,disk`: 2 short model calls), and `--safe-mode` is now the second
   layer (follow-up of 2026-11-20). Update 2026-11-20: (a) is closed by the one-run positive control with the real configuration (section
   "Follow-up of 2026-11-20"): the owner's own hooks did fire under the real login without the flags (4 hook starts)
   and none did with them. (d) is narrowed: with the flags alone the init event lists one memory path, with
   `--safe-mode` none.
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
- Lintel does not tell participants that a cloud provider processes the meeting; the consent tells the user (from
  2026-11-20: the notice and "Details" tell the user; no window).
- One consent (from 2026-11-20: one choice) covers all meetings, including confidential ones, until the user
  switches back.
- From 2026-11-20 also: no record of the act, no new question when the data scope grows or the company changes, a
  setting written outside the UI counts as a choice, an accidental menu choice starts sending (full list in the
  amendment).
- The marker does not record partial or failed sends.
- The CLI changes weekly: argv lives in one pure function with golden tests, the version range is checked, the
  canary is repeated per range.
- An authentication variable in Lintel's environment (for example `ANTHROPIC_API_KEY`) is passed through, and the
  CLI may then bill per token. The panel warns about it.

## Consequences

- PR 2 builds `LintelProviders` against this list of flags (including `--safe-mode`, which was added after that PR was opened: its golden argv test and its required-flag check need the extra entry), with `isolationVerified = false`, and ships the tests
  of decision 9: the golden argv holds every required flag with an empty value where one is required and none of
  the forbidden ones; the environment handed to the process is exactly the allowlist; the working directory is new
  and empty; a descriptor whose argv lacks a required flag is refused before `Process.run()`.
- The spec is corrected where the canary disagreed (allowlist, error reporting, truncation, confirmed session files).
- `docs/perf.md` has the measured rows and the rows still "not yet measured".
- The built-in model path and every existing setting are unchanged.

## Amendment of 2026-11-20: choosing the provider is the consent (owner decision; draft pending mock-up acceptance)

Source: the owner's notes on the provider/model selection mock-up v2 (2026-11-20, with the addendum), the owner's
condition on the core pull request (#205) and the owner's decision D15. Status of this amendment: **draft on a
branch**; it is opened as a pull request only after the owner accepts the mock-up and settles the open points
below. It **supersedes decisions 2 and 3 in the parts marked "superseded"** and adds the conditions below to decision 8. Nothing here
softens a limit on the owner's behalf: mitigations are listed as undecided options.

### Decisions (owner, 2026-11-20)

1. **The consent is the provider chosen in Settings.** There is no versioned window and no confirmation sheet. At
   the moment of choosing an external provider the UI shows a fixed, short notice (one or two sentences: the
   transcript, the speaker names and the approved dictation vocabulary terms go to the provider, with the company
   name taken from the descriptor's `recipient`) and a non-modal "Details" link that expands the full list in
   place. Changing the model at the same provider asks nothing. `ProviderRunner` still refuses to start a
   content-carrying process when no provider is chosen, and the setting is read fresh before every process (not
   cached in the job).
2. **Provider, then model; it must scale** to several providers and ways of connecting: local models; CLI tools
   on a subscription (Claude Code today; Codex/ChatGPT, Pi, OpenCode are a direction, **not a commitment**); an API
   key (Phase 2). The notice is one shared sentence pattern with the chosen company's name.
3. **D15: Claude Code models are the aliases `haiku`, `sonnet`, `opus`, `fable`; the default is `sonnet`.** Quality
   gate G is measured only for `sonnet`; the other three are "not measured" in the docs, and the input budgets for
   `opus` and `fable` are an assumption. The UI notes the higher use of the subscription limit and the longer time
   for `opus` and `fable`. An alias points to the newest model known to the CLI version and changes over time.
4. **Condition: `isolationVerified` is never switched on its own.** It may become `true` only (i) in the same pull
   request as the Settings UI for choosing the provider (PR 6 of the plan), so that sending cannot be enabled
   without the visible notice (today the two settings keys could be set with `defaults write`), and (ii) after a
   measurement on the real Claude Code CLI with synthetic data only. A pull request that changes only that line, or
   its pinned test, is refused. (Decision 8 above is read together with this.)
5. **The prompt version `whole1+cli1` is stored in the existing `notes_prompt_version` column** (technical; no
   migration).
6. **No fallback to the local model after a refusal or an error.** Whether the job should be queued again, and on
   what, is open (D7 of the mock-up).

### What replaces what

| Decision | Before | After |
|---|---|---|
| 2 (consent) | One consent window at choice time, naming provider and model, speaker names, times, automatic re-runs | Superseded: the choice is the consent; fixed notice and "Details" list the same things |
| 3 (gate) | A change of provider or model needs a new consent; a version bump of the consent text invalidates the stored one | Superseded: a change of model needs nothing; a change of provider has no separate question (open); there is no consent text version |
| 3 (enforcement) | Authorization closure before each process, after the queue | Unchanged; the closure now compares the request's provider and model with the setting read at that moment |
| 4 (no-content processes) | No consent | Unchanged (no consent in the sense of a window; "Try it" is available after a provider is chosen) |

### What this weakens (risk accepted by the owner's decision of 2026-11-20)

Checked against the spec `.ai/specs/2026-11-10-external-ai-providers.md` and ADR 0013 as on `main` on 2026-11-20.

- **No proof of the act, its date or the text version.** Before: `providerConsent = {provider, model, feature, at,
  textVersion}` saved after "Turn On". After: the settings alone. Later nobody can show what the user saw and when.
- **No new question when the kind of data sent grows.** Before: a version bump invalidated the consent and the
  window came back. After: a new kind of data leaves after an app update without a question. **Concretely
  (ADR 0013): a user who chose Claude Code before the update starts sending the approved dictation vocabulary terms
  after it, with no new question,** and this includes terms typed by hand before the change.
- **An accidental menu choice starts sending.** One click, or arrow plus Return with the keyboard or VoiceOver; the
  next meeting, an automatic retry, a background resume or "Regenerate Notes" sends the whole transcript with
  speaker names.
- **Changing the model at the same provider asks nothing, and changing it during a job sends again.** A different
  model has different usage terms, limits and possibly a different path at the provider; changing it during a job
  stops the process and restarts the whole job on the new model (the spec: notes are never stitched from two models),
  so the transcript leaves a second time. A model typed as a custom identifier (if that item stays) sends the same way.
- **A setting that did not come from the UI is a choice** (`defaults write`, a restored backup, settings copied from
  another Mac): sending starts with no act by the user on this Mac. Before, such a value without a consent record
  behaved like the built-in model plus a banner. The condition in decision 4 holds this back only until
  `isolationVerified` is switched on, in the pull request with the UI.
- **A change of company, or of channel at the same company, asks nothing.** Before: "each is a new descriptor and a
  new consent". A subscription-to-API-key switch changes both the terms (API terms, pay per use) and the scope of
  data (no vocabulary terms, ADR 0013).
- **The consent is no longer tied to the feature** (`ProviderFeatureID`: "future consumers need their own, new
  consent"). Whether a future feature inherits the choice is undecided.
- **Participants are still not told by Lintel, and the reminder is less visible.** Unchanged in substance (accepted
  2026-11-19); before it was said in a window the user had to click, now only in "Details", which may stay closed.
- **One choice covers every meeting, confidential ones and automatic runs included.** Unchanged in substance; an
  unnoticed choice is easier without a window. The banner "Transcripts leave this Mac" stays.
- **"Try it" can no longer be used before the consent**, because choosing and consenting are one act.

### Undecided options (mitigations; none chosen)

Until the owner decides, the behaviour is the one without a mitigation.

- Record `at` and an `infoVersion` at choice time; on a change of the data scope, suspend sending and show an inline
  banner "Review" (today's semantics without the window), or a banner without suspension, or nothing (release notes).
- "Undo" in the banner for a few seconds after a choice, during which nothing starts; or a second click "Confirm" for
  the first choice after installation; or the notice above the list the first time an external provider is picked.
- A model change during a job waits for the job to end instead of restarting it.
- Mark settings with an installation-bound `chosenAt`; a value written outside the UI sends nothing and shows
  "Confirm your choice".
- The first choice of each company (not model), and a switch of channel, shows the notice inline and asks to confirm.
- Put the sentence about participants into the short notice.
- Keep the consent per feature, global, or leave it open until the spec of the next feature.

### Contradictions and points for the owner (listed, not settled)

1. The spec's Problem Statement says sending must be impossible "without a conscious consent: not through ... an old
   setting". After this decision an old setting with a chosen provider is the consent.
2. D15 against "the canary is repeated for every new scope" and "G is repeated for a new prompt version": `opus` and
   `fable` are accepted as not measured. Open: should the isolation canary be repeated for them before they appear
   in the menu, although G will not be.
3. The spec offers a "custom identifier" model entry; decision 3 lists four aliases. Open (D15): does the entry stay.
4. "No fallback" against PR 7 and the key `notesProviderFallback` (default off, provider to built-in only). PR 7 is
   on hold until D7; nothing of it is built.
5. Decision 8 said setting the flag stays the owner's decision; the spec said it is set after the canary of PR 1;
   decision 4 above adds that it happens only in the UI pull request and after a real-CLI measurement. Until then
   nothing can be sent from the app, not even "Try it".
6. "A model is not a gate" against the authorization closure comparing the request's model with the current choice:
   it makes a model change in the menu apply from the next process, at the price of a restart (see above).
7. Whether the second sentence "Choosing this provider means your consent" stays in the notice (D13) decides whether
   the act is stated in words anywhere.
