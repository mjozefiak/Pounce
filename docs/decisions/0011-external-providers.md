# ADR 0011: External AI providers for meeting notes (Claude Code CLI first, API key second)

- Status: **Accepted** for the decisions below (owner decisions of 2026-11-19, recorded in
  `.ai/specs/2026-11-10-external-ai-providers.md`). **`isolationVerified` stays `false`** in the descriptor until
  canary point 5 (TCC inheritance for a child of Lintel) is closed by the owner; see "What is not verified".
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

## Canary results

Method: `scripts/provider-canary/canary.py`; the environment allowlist of the spec plus `USER`; working directory an
empty temporary directory (a decoy project for the isolation probes); private `TMPDIR`. Counts and paths only; no
content was recorded.

### Flags (golden list for the descriptor)

`claude -p --model <m> --output-format json --tools "" --no-session-persistence --disable-slash-commands
--strict-mcp-config --setting-sources "" --system-prompt <static text>`, content on stdin. All of them exist and
work in 2.1.328 (every canary call used them). Notes:

- `--bare` stays unusable with a subscription (it reads only `ANTHROPIC_API_KEY`); it is the candidate for Phase 2.
- `--safe-mode` exists in this version ("all customizations disabled", auth and built-in tools still work). It was
  not needed; it is the fallback if `--setting-sources ""` ever stops covering a source.
- The aliases `sonnet` and `haiku` are accepted by `--model`.
- stdin works for a prompt of at least 56 000 tokens (below).
- The binary is a native Mach-O arm64 file (`~/.local/bin/claude` is a symbolic link into
  `~/.local/share/claude/versions/<version>`), owned by the user, not group or world writable. It does not need
  `node` on `PATH`, so the fixed `PATH` `/usr/bin:/bin:/usr/sbin:/sbin` is enough. An npm install (needs `node`)
  was not tested; the spec's default (support it only through "Choose file…") stands.

### Spec table

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | File tools | **Pass.** With `--tools ""` the model could not read a file outside the working directory; the answer did not hold the file's token. | Init event: `tools` is empty. The positive control (tools allowed) did read it. |
| 2 | Shell | **Pass.** The marker file was not created. | The control created it. |
| 3 | Hooks | **Pass for project hooks; user-level hook modules shown unloaded.** The decoy project hook did not run. In the debug log the CLI loads 2 user-level hook modules without `--setting-sources ""` and 0 with it (4 built-in modules in both). | The control ran the project hook. Command hooks in the user's own `settings.json` were not observed directly (see below). |
| 4 | `CLAUDE.md`, MCP, plugins | **Pass.** The project token was not in the answer, the decoy MCP server was not launched; init reports 0 MCP servers, 0 skills, 0 slash commands. Init lists 4 plugins and 6 agents, which are built-in (the user's own plugins are the user-tier modules above). | The control answered the token and launched the MCP server. |
| 5 | TCC inheritance | **Not verified.** See below. | |
| 6 | Copies on disk | **Pass.** 0 files with a canary from the 5 isolated calls among 168 files modified in the scanned roots (CLI config directory, home caches and logs, system temp, working and temp directories). The control call, run without `--no-session-persistence`, left the transcript and answer in `~/.claude/projects/<encoded working directory>/<uuid>.jsonl` (1 file): this confirms the spec's assumption and proves the scan can find a copy. The script removed that file. | The scan stopped at 400 000 entries in `~/.cache`. |
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
2. **Command hooks in the user's own `settings.json`.** The decoy project hook and the debug log's user-level hook
   modules were observed; a user-level command hook was not made to fire or not fire, because that would change the
   owner's real configuration or need a separate login. `--setting-sources ""` excludes the user source, and the
   CLI loaded 0 user-tier hook modules with it. Residual risk: a future CLI version moves a source outside the flag.
   Mitigation: `isolationVerified` is tied to a version range, the canary is repeated for every new range, and
   `--safe-mode` is the fallback.
3. Another account's login and other install methods (npm, Homebrew) were not tested.
4. A real hour of meeting: all input was synthetic; no real transcript or speaker name was sent.
5. The disk scan is bounded (400 000 entries per root; `~/.cache` was cut). A copy outside the scanned roots would
   not be seen.

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

- PR 2 builds `LintelProviders` against this list of flags, with `isolationVerified = false`.
- The spec is corrected where the canary disagreed (allowlist, error reporting, truncation, confirmed session files).
- `docs/perf.md` has the measured rows and the rows still "not yet measured".
- The built-in model path and every existing setting are unchanged.
