# ADR 0010: Context-aware dictation (trust model, frozen contract, reference phrases)

- Status: **Accepted** (owner decision of 2026-11-19: the DICT-0.1 gate is passed and the epic starts). Until
  the DICT-0.2 probes are run, the points marked **[0.2]** are working values, not decisions.
- Date: 2026-11-19
- Backlog: `.ai/specs/backlog/2026-11-13-epic-context-aware-dictation.md`, story DICT-0.3. Owner decisions of
  2026-11-19 (numbers 1, 6 and 7) are applied; they are recorded in the backlog overview (PR #104, merged).
- Number 0010: free on `main` and in the open pull requests (checked 2026-11-19). `0007` is used twice.
- Owner decisions on this ADR (2026-11-19, accepted):
  1. DICT-2.1 may start before the DICT-0.2 probes; the probes must be done before DICT-2.2.
  2. The decision-7 change is `CleanupPrompt` version 2; the list of terms (DICT-4.2) is a later prompt
     version.
  3. `CleanupPrompt` version 2 ships only after it passes the self-correction corpus (PR #115). `known_bad`
     cases are reported separately and never masked, and the result is reported for each built-in model.
  4. `FieldKind` is an open set, like `FocusContextSource` and `SkipReason`.

**How to read the marks.** **[0.2]** means "to be confirmed by the DICT-0.2 probe" (in the backlog's language:
*do potwierdzenia próbą DICT-0.2*). The probes (Accessibility read matrix, terminal context, pasting into TUI
tools, clipboard access behaviour) have not been run. This file holds no probe result and no measurement. A
story that depends on a **[0.2]** point must not merge before the probe fills that point in.

## Context

Dictation today knows nothing about where the text will land. The epic adds one local, time-limited snapshot
taken when the shortcut is pressed (application, kind of field, text around the caret, selection, window, and in
a terminal the working directory). Swift rules use it: a user dictionary, insertion rules, and spoken references
to the clipboard or to a file. Reading the text of another application is a new purpose of the Accessibility
grant, so it needs its own trust model before any code.

Two owner decisions changed the starting point of this ADR:

- **The DICT-0.1 gate was passed by owner decision, without a baseline** (decision 6).
- **Cleanup must remove retracted fragments** (decision 7), which overrides the backlog's D-Q10 assumption
  that `CleanupPrompt` stays at version 1 during Phases 0 to 3.

## Decision 1: the trust model

### The rules that never change

1. **Off means nothing is read.** `plugins.dictation.contextEnabled = false` (the default) is the master switch:
   the port is never called, and the clipboard and the file system are not read either, whatever
   `clipboardReference` and `fileReferences` say. A source that is not in `contextSources` is not in the request.
2. **The snapshot lives in memory for one dictation.** It is cleared on paste, on cancel and on error. Nothing
   from it is written to a log, `ranking.sqlite`, `dictation.sqlite`, a crash report or diagnostics. Field
   lengths are not logged either. The one exception is what dictation stores today or by rule 5: the bundle id
   and the profile name (`app_profile`). The same holds for every other source: the clipboard content, file
   names and paths from the listing, the terms of the user dictionary, and the dictated text itself (raw,
   cleaned, or with a resolved reference inserted) never reach a log, a crash report or diagnostics. Logs carry
   source names, durations, skip reasons and error codes only.
3. **The snapshot is used by Swift rules only.** It is not part of any LLM prompt in Phases 0 to 3.
   **Everything a reference resolves to is inserted by Swift and never passes through a formatter:** the
   clipboard text, a file path found on disk, the path behind "ten plik". The formatter, and the continuity
   block built from the previous chunk, see spoken words only. DICT-3.4 and DICT-3.5 need the same test as
   DICT-3.1 criterion 4 (a recording formatter that receives no resolved content).
4. **Dictation context never goes to an external provider.** This holds in every phase and for every provider
   (Claude and any later one), and also for "My server". The owner switched external providers on for the
   product (decision 1 of 2026-11-19); for dictation that covers the dictated transcript only, after the user's
   consent. The snapshot, the clipboard content, the user dictionary and file names are never added to a
   request that leaves the process. Changing this rule needs a new ADR.
5. **History stores names of sources, never content.** `dictation_entry.context_sources` holds values from a
   closed list: `vocabulary`, `profile`, `field`, `selection`, `window`, `terminal`, `clipboard`, `files`.
6. **A failed read is "no context", never a failed dictation.** Recording and the HUD start without waiting
   for the snapshot.

A name that may confuse: `CleanupPrompt` already has a `<context>` block. That block is the end of the previous
paragraph of the same dictation, used for continuity. It is dictated text, not the snapshot, and it follows the
rules of the transcript.

### Trust table

This table is the single source for the consent sheet, the Context pane and the website text (DICT-2.4).

| Source | When it is read | Limit | Where it goes | How long it lives | Hard refusals |
|---|---|---|---|---|---|
| Application (bundle id, pid) | At the shortcut press, when `contextEnabled` or `appProfiles` is on | One identifier | Profile rules; the profile name goes to history (`app_profile`) | Bundle id as today in history; pid in memory for one dictation | None (the bundle id is already read today for history) |
| `window`: title and document of the focused window | At the shortcut press | One title, one document URL | Nothing in Phases 0 to 3 uses it yet; the document may serve "ten plik" (**[0.2]**) | Memory, one dictation | No Accessibility grant; application on the denied list; Lintel's own windows. Whether the document attribute is reliable: **[0.2]** |
| `field`: kind of the focused field, text before and after the caret | At the shortcut press | 500 characters before, 200 after, read by range, never the whole value | Insertion rules use at most the last two characters before the caret and the first one after it | Memory, one dictation | Secure text field; Secure Event Input active; no grant; denied application; Lintel's own windows; time limit |
| `selection`: selected text | At the shortcut press | 2000 characters | Nothing in Phases 0 to 3 uses it yet. The consent text must say so, or the source stays out of the default list until a rule needs it | Memory, one dictation | Same as `field` |
| `terminal`: foreground process name and working directory | At the shortcut press, only when the user switched this source on (it is not in the default list) | One process name, one path | Profile `agentCLI`, root folder for file lookup | Memory, one dictation | Source off; a process of another user; no certain match of the active tab (**[0.2]**); `ssh` and `tmux` give no directory |
| `clipboard`: text of the clipboard | Only when the user spoke a clipboard phrase as a whole segment and `clipboardReference` is on | 20 000 characters of text; or, for "ten plik" with `clipboardReference` and `fileReferences` both on, exactly one file URL | Pasted verbatim by Swift into the result (for a file URL: the path in the target's syntax). The formatter never sees the content or the marker | Not kept. History stores the marker `⟦schowek⟧` | Setting off; concealed or transient marker types; content that is neither text nor exactly one file URL; over the limit; `accessBehavior` other than "always allow" (**[0.2]**) |
| `files`: file names under the terminal's working directory | Only when the user spoke a file trigger and `fileReferences` and `terminal` are on | Depth 8, 50 000 entries, 20 results, time limit | One verified relative path, inserted by Swift after formatting | Listing cache in memory until the dictation ends. The pasted path is dictated content and stays in history | A place macOS protects with a privacy prompt without Full Disk Access (checked before any file-system call); `node_modules`, `.git`, `.build`, `DerivedData`; remote terminal |
| `vocabulary`: the user's own terms | After formatting | The user's file | Deterministic replacement in Swift | `Plugins/dictation/vocabulary.json` (0600) until the user removes it or erases the data | None. Terms are not logged |

Known limit, stated to the user: a web page can build a password field from an ordinary text field. Lintel
cannot detect that. The text of a field is never stored and never sent, which bounds the damage.

### Consent

- No new system grant: the read uses the Accessibility grant dictation already declares. The purpose is new, so
  there is an in-app consent sheet, shown every time the user turns the switch on, also on existing installs.
  Nothing appears by itself (D-Q1, D-Q2).
- The `terminal` source and the clipboard and file references each have their own switch, all off by default
  (D-Q6, D-Q14).
- The Accessibility row in Settings → Permissions is reworded to name three purposes: pasting, moving windows,
  reading the text field while dictating (when on).
- Lintel never writes an attribute to another application and does not set `AXManualAccessibility` or
  `AXEnhancedUserInterface` (D-Q9).

### Default denied applications (`contextDeniedApps`)

Closed list of bundle identifiers for the default value. For these the port is not called and the snapshot
holds the application only. The user can add and remove entries.

| Application | Bundle identifier | Checked |
|---|---|---|
| Passwords (Apple) | `com.apple.Passwords` | read from the application's `Info.plist` on the author's Mac, 2026-11-19 |
| Keychain Access | `com.apple.keychainaccess` | not checked on an installed copy |
| 1Password 8 | `com.1password.1password` | not checked on an installed copy |
| 1Password 7 | `com.agilebits.onepassword7` | not checked on an installed copy |
| Bitwarden | `com.bitwarden.desktop` | not checked on an installed copy |
| NordPass | `com.nordsec.nordpass` | read from the application's `Info.plist` on the author's Mac, 2026-11-19 |
| KeePassXC | `org.keepassxc.keepassxc` | not checked on an installed copy |
| Dashlane | `com.dashlane.dashlanephonefinal` | not checked on an installed copy |
| LastPass | `com.lastpass.LastPass` | not checked on an installed copy |
| Enpass | `in.sinew.Enpass-Desktop` | not checked on an installed copy |
| Proton Pass | `me.proton.pass.electron` | not checked on an installed copy |

DICT-2.3 must check every "not checked" identifier against the vendor's current build before it ships the
default (KeePassXC in particular has had more than one identifier). An identifier that cannot be confirmed is
dropped from the list, not guessed. The list is a second
line of defence: secure fields are refused by the port whatever the application is.

## Decision 2: what the cleanup model may do (owner decision 7, D-Q10 overridden)

The owner wants dictation to remove changes of mind and self-corrections ("albo jednak", "nie, czekaj") and
produce a sensible message. So `CleanupPrompt` changes before Phase 4. This ADR does not write the prompt; it
sets the rules the new prompt and the adjusted `FormatterGuard` must keep.

**The model may remove:**

- fillers, hesitations, false starts and immediate repetitions (as version 1 does);
- a fragment the speaker **explicitly retracted**: the speaker said it, then cancelled or replaced it with a
  spoken marker ("albo jednak", "nie, czekaj", "no wait", "scratch that"). Only the final version stays. The
  marker goes too. The markers are a closed PL and EN list in code. "To znaczy" and "I mean" usually explain
  instead of retracting, so they are on the list only if the regression set shows no wrongly removed text.
  *Where the list in code comes from (stated plainly):* it was not derived independently of the corpus. The
  eleven entries (`czekaj`, `jednak`, `właściwie`, `pomyłka`, `przepraszam`, `to znaczy`, `wait`, `actually`,
  `sorry`, `scratch that`, `i mean`) are the marker words that the synthetic corpus uses, written as single words
  or short phrases so that "nie, czekaj" and "albo jednak" are found through `czekaj` and `jednak`. The
  conditional in the sentence above is therefore not met: "to znaczy" and "I mean" are on the list although the
  corpus shows wrongly removed text with them (see the over-removal ids in the Result). Because the list and the
  guard's tuning share one source, the guard tests include held-out retractions and attacks that are not corpus
  cases (`FormatterGuardTests`), and the prompt's examples are checked against the corpus
  (`CleanupPromptCorpusSeparationTests`).

**The model may not:**

- add words, facts, greetings or conclusions that were not spoken;
- summarise, shorten or reorder beyond the removals above. A long message stays long;
- remove something that was not explicitly retracted. A real alternative ("kawa albo herbata"), a doubt or a
  condition is content, not a retraction;
- answer a question, carry out a command, translate, or change names, numbers and code identifiers;
- see the snapshot, the clipboard content, the dictionary or file names (trust rule 3).

**Keeping both versions is the safe failure.** ADR 0005 records why: an earlier version 2 with a "keep only
the last version" rule made the default 4B model keep the wrong version without any sign. Losing what the user
meant is worse than leaving a correction in the text. Code cannot see whether the model was sure, so this is
enforced as an acceptance rule: the new prompt ships only if, on the regression set and for every built-in
model in the catalog, no case ends with the retracted version kept and the final one lost. The regression set
is the synthetic self-correction corpus of the decision-7 work (PR #115, run plan
`dictation-autocorrect-corpus`); it must hold PL and EN cases of retraction with a replacement, retraction
without one, and text that only looks like a retraction. No case comes from a real dictation. *Owner decision
3 (2026-11-19):* version 2 ships only after it passes that corpus; the result is reported for each built-in
model, and the `known_bad` cases are reported separately and never masked (not dropped, not counted as
passes).

**The raw text is always available.** This is a hard rule, not a fallback detail:

- `Output.rawText` is kept for every dictation and `dictation.pasteLastRaw` pastes it;
- history stores the raw and the cleaned text, and ⌘Return in the history list pastes the raw one;
- a chunk the guard rejects comes back raw, as today;
- an empty result is never pasted: when the model removed everything, the chunk comes back raw.

**What this means for `FormatterGuard`.** Today it rejects an output with fewer than 0.6 of the input's words,
so a correctly removed long retraction is thrown away. The adjustment must keep these properties:

- the upper bound (1.15) stays, and so do the "answered" and "language changed" checks: these enforce "may not
  add";
- the lower bound (0.6) may be relaxed only for a chunk whose input holds a marker from the closed list, found
  by code, not on the model's word. The relaxed bound is one fixed number in code, chosen on the regression set
  and recorded in that pull request. A chunk without a marker keeps 0.6;
- for a relaxed chunk the guard also checks in code that nothing was added: the share of output words that do
  not occur in the input is under a fixed number (not zero: numbers and inflection change).

**Version numbers.** The decision-7 change is `CleanupPrompt.version` 1 → 2, a user-visible behaviour
(`BACKWARD_COMPATIBILITY.md` sections 3 and 5: release note, a new golden prompt file). DICT-4.2 (a list of
terms in the prompt) keeps its own condition and is a later version. *Owner decision 2 (2026-11-19):*
accepted; the list of terms is not part of decision 7. The backlog text of DICT-4.2 still needs an edit (not
made in this PR): its surfaces say "1 → 2" and `prompt-v2.txt`, and its criterion 4 says the prompt "stays in
version 1" for other sources; both must name the version after version 2 instead.

**Known limits.**

- A voice reference is recognised in Swift before formatting. A retraction spoken after "wklej schowek" does
  not cancel the paste. The HUD confirmation with Esc (first five uses) is the way to cancel.
- Formatting runs chunk by chunk while the user speaks. A retraction of something said in an earlier chunk
  cannot be removed: that chunk is already formatted, and the model sees only its end as the continuity block.

## Decision 3: the frozen contract

Additive only, every new member with a default (`BACKWARD_COMPATIBILITY.md` section 1). DICT-2.1 adds the focus
types, DICT-3.3 adds `FileNameLookup`. No other shape is allowed without changing this ADR first.

```swift
public protocol FocusContextReader: Sendable {
    /// Never throws. A source that could not be read is in `skipped`.
    func snapshot(_ request: FocusContextRequest) async -> FocusContext
}

/// Open set: a struct with a raw value, so a new value breaks no `switch`.
public struct FocusContextSource: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String)
    public static let window, field, selection, terminal: FocusContextSource
}

/// Open set, same reason.
public struct SkipReason: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String)
    public static let secureField, timeout, unsupported, notPermitted, denied: SkipReason
}

/// Open set. `none`: no focused text field. `secure`: text is never returned.
public struct FieldKind: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String)
    public static let none, text, secure, terminal: FieldKind
}

public struct FocusContextRequest: Equatable, Sendable {
    public var sources: Set<FocusContextSource>
    public var maxCharactersBeforeCaret: Int  // default 500
    public var maxCharactersAfterCaret: Int   // default 200
    public var maxSelectionCharacters: Int    // default 2000
    public var budget: Duration               // default 250 ms for the whole snapshot
    public init(
        sources: Set<FocusContextSource>, maxCharactersBeforeCaret: Int = 500, maxCharactersAfterCaret: Int = 200,
        maxSelectionCharacters: Int = 2000, budget: Duration = .milliseconds(250))
}

public struct FocusContext: Equatable, Sendable {
    public var bundleID: String?
    public var processID: Int32?
    public var field: FieldKind               // default .none
    public var textBeforeCaret: String?
    public var textAfterCaret: String?
    public var selectedText: String?
    public var windowTitle: String?
    public var documentURL: URL?
    public var terminal: TerminalContext?     // default nil
    public var skipped: [FocusContextSource: SkipReason]
    public init(
        bundleID: String? = nil, processID: Int32? = nil, field: FieldKind = .none, textBeforeCaret: String? = nil,
        textAfterCaret: String? = nil, selectedText: String? = nil, windowTitle: String? = nil,
        documentURL: URL? = nil, terminal: TerminalContext? = nil, skipped: [FocusContextSource: SkipReason] = [:])
}

public struct TerminalContext: Equatable, Sendable {
    public var foregroundProcess: String?     // the process name, for example "claude"
    public var workingDirectory: URL?         // nil when remote
    public var isRemote: Bool                 // ssh, tmux
    public init(foregroundProcess: String? = nil, workingDirectory: URL? = nil, isRemote: Bool = false)
}

public struct NoFocusContextReader: FocusContextReader  // field .none, no text, every requested source .unsupported

public protocol FileNameLookup: Sendable {
    func files(matching tokens: [String], under root: URL, limit: Int) async -> [URL]
}

// PluginContext, new parameters with defaults:
//   focusContext: any FocusContextReader = NoFocusContextReader()
//   fileNames: (any FileNameLookup)? = nil
```

Notes on the shape:

- **Deviation from the backlog, accepted by the owner (2026-11-19, owner decision 4):** `FieldKind` is an open
  set like the other two. The backlog (DICT-2.1) names only `FocusContextSource` and `SkipReason` as open; a
  closed `FieldKind` would break plugins the first time a kind is added, so it follows the same rule.
  Which kinds Accessibility can tell apart beyond these four: **[0.2]**. `FocusContext.field` is not optional;
  code that holds an optional snapshot must unwrap it before comparing with `.none`, or the comparison reads as
  `Optional.none`.
- Every struct has an explicit public initialiser with defaults (a public struct gets none for free), so
  plugins and tests can build values.
- The snapshot's age is not in the contract. The plugin records the time itself and compares the pid before
  pasting (older than 120 s or another pid: insertion rules are skipped; the 120 s value comes from DICT-2.5
  and is confirmed in the dogfood, DICT-3.6).
- Every probe-dependent member is optional and may stay `nil` (`documentURL`, `terminal`). So a negative probe
  result changes behaviour, not the shape. That is why the shape can be frozen before the probes; the values
  below cannot.
- The implementation (DICT-2.2) checks `AXIsProcessTrusted()`, uses one serial queue per pid like
  `AXWindowClient`, and removes invisible Unicode characters (directional, zero width) before it returns text.

### Limits

| Limit | Value | State |
|---|---|---|
| Text before the caret | 500 characters | decided |
| Text after the caret | 200 characters | decided |
| Selection | 2000 characters | decided |
| Whole snapshot | 250 ms, then dictation runs without context; `snapshot` returns within 300 ms | decided as a budget, not measured |
| One Accessibility call | 250 ms working value (the `messagingTimeout` `AXWindowClient` uses today) | **[0.2]**: the probe gives the real return time with a stopped main thread and the recommended value |
| Clipboard reference | 20 000 characters, text only | decided |
| File lookup | depth 8, 50 000 entries; over either the result is empty. Results are cut at `limit`, at most 20 | decided |
| Paste warning for agent CLIs | over 800 characters or 3 lines; the text is not shortened | **[0.2]**: the probe checks where each tool folds a paste |

### Terminal: when the context is certain

Working rule, **[0.2]** as a whole (probe criteria 3 and 6):

- the frontmost application is a known terminal (Terminal, iTerm2, Ghostty in the probe);
- exactly one tab can be matched to a foreground process group and its working directory. Any doubt gives
  `terminal == nil` and `skipped[.terminal] == .unsupported`;
- `ssh` or `tmux` in the foreground gives `isRemote == true` and no directory, so file references are off for
  that dictation;
- a process of another user gives `nil`, without an error.

If the probe shows a certain match in fewer than two of the three terminals, DICT-3.2 to DICT-3.5 are paused
and Phase 3 ends at DICT-3.1. The types stay in the contract and stay `nil`.

### Voice references

- **Clipboard** (D-Q6): a closed list of phrases, and the phrase must be a whole segment between pauses. The
  list is in `reference-phrases.json` (`clipboardPhrases`). The same words inside a sentence are prose.
- **File** (D-Q8): a trigger word ("małpa", "at", "tag") followed by a name, or a name with a spoken extension
  ("kropka swift", "dot swift"). The word "plik" or "file" alone triggers nothing. One winner that exists on
  disk, or the words stay as spoken.
- **Where a file name starts.** The name is a run of at most four words directly after the trigger or directly
  before the spoken extension. The resolver tries the longest run first and takes the first run whose words
  equal the name tokens of exactly one file (with the extension, when one was spoken). In "zmień port w settings
  kropka yaml" the runs "port w settings" and "w settings" match nothing and "settings" with `yaml` matches one
  file. Working rule for DICT-3.4; the reference phrases are written to it.

Mention syntax per tool, working table, **[0.2]** as a whole (probe criterion 4). If the probe does not confirm
a row, that tool gets the plain relative path.

| Foreground tool | Inserted text | Path with a space |
|---|---|---|
| `claude` (Claude Code) | `@` + path relative to the working directory | **[0.2]** |
| `codex`, `aider`, `gemini` | plain relative path | **[0.2]** |
| a shell, or an unknown tool | plain relative path | shell quoting; **[0.2]** for the exact form |
| outside a terminal | nothing: there is no folder to search under | — |

## Decision 4: non-goals of the dictation spec that this ADR overturns (D-Q11)

`.ai/specs/2026-11-01-voice-dictation.md` lists as out of scope "reguły per aplikacja" (rules per application)
and "słownik własnych słów" (a user dictionary). Both are **overturned** for this epic: application profiles
(DICT-1.3) and the user dictionary (DICT-1.1) are in scope. "Własne tryby i prompty" (user modes and prompts)
**stays out of scope**. The non-goal "modele i usługi w chmurze" is not touched here; the external providers
spec and owner decision 1 of 2026-11-19 govern it, within trust rule 4 above.

## Baseline: the DICT-0.1 gate was passed without a measurement

DICT-0.1 was to count, on the owner's own dictation history, how often file names, identifiers and clipboard
references occur, and stop the epic under 5 in 20. **The owner passed the gate on 2026-11-19 without the count
and accepted that there is no baseline** (decision 6). No history was read and no number exists. This is an
accepted risk, recorded here so no later document reads as if a baseline had been taken.

What follows from it:

| Consequence | What we do instead |
|---|---|
| The success metric "dictations that need a manual correction of a name: down by at least half" has no "before" number. A before-and-after claim cannot be made. | DICT-3.6 reports absolute numbers from the dogfood: dictations, uses per source (`context_sources`) and false substitutions recorded by hand. |
| The stop criterion (under 25%: do not build) was not applied. The feature may turn out to be rarely needed. | Every feature is off by default and each phase ships alone. DICT-3.6 stays the gate for the defaults and for Phase 4. |
| D-Q13 (at most 2% false replacements from the phonetic prototype) has no data. | DICT-4.1 stays paused until it has its own measurement. The dictionary (DICT-1.1) uses exact matching. |
| The regression set of the owner's transcripts (D-Q4) does not exist. | Tests use synthetic phrases only (`reference-phrases.json`). No real dictation is in the repository or beside it. |

*Recommendation, not a decision:* a comparison is still possible inside the dogfood, one week with context off
and one week with it on, counted by the DICT-0.1 rules. It would give the missing "before". The owner decides
whether it is worth the two weeks.

## Reference phrases

`Tests/DictationPluginTests/Fixtures/context/reference-phrases.json` holds the fixed set DICT-3.1 and DICT-3.4
are judged against (0 false substitutions in the `none` class; at least 90% in `clipboard`). Every phrase is
synthetic: written for this file, none taken from a real dictation or meeting. Each has a language, the
segments between pauses, and the expected result (`clipboard`, `file`, `none`). File phrases name the expected
path in the file's small synthetic tree. A `none` phrase is either `prose` or `unresolved` (a reference that
must not resolve: no such file, or two files match). `ReferencePhrasesFormatTests` checks the format: at least
60 phrases, no phrase without a class, at least 20 plain-prose phrases in `none`, at least 15 in each other
class, both languages in every class. Segments are compared with the clipboard phrases after lowercasing and
trimming punctuation, because a real transcript reads "Wklej schowek.".

The set may grow. A phrase is never removed or relaxed to make a resolver pass.

## Budgets

Added to `docs/perf.md` with an empty "Measured" column; DICT-2.7 and DICT-3.3 fill them in. Snapshot at most
250 ms; rules after transcription at most 20 ms for 500 words; `FileNameLookup` at most 50 ms with a warm
cache and 300 ms on the first listing, at most 20 results.

## Open points

| Point | Filled in by | Blocks |
|---|---|---|
| Accessibility matrix (application × attribute, times) | DICT-0.2 criterion 1 | DICT-2.2 |
| Per-call time limit | DICT-0.2 criterion 2 | DICT-2.2 |
| Terminal rule; whether Phase 3 goes past DICT-3.1 | DICT-0.2 criteria 3 and 6 | DICT-3.2 to 3.5 |
| Mention syntax per tool, paste folding | DICT-0.2 criterion 4 | DICT-3.4, DICT-3.5 |
| Clipboard `accessBehavior` and the alert on macOS 26 and 27 | DICT-0.2 criterion 5 | DICT-3.1 |
| Whether the window's document can stand in for "this file" | DICT-0.2 criterion 1 | DICT-3.5 |
| Unchecked identifiers on the denied list | DICT-2.3 | DICT-2.3 |
| Off/on comparison in the dogfood | owner | DICT-3.6 |

Closed on 2026-11-19: `FieldKind` as an open set (accepted, owner decision 4) and the backlog text of DICT-4.2
(edited to match owner decision 2).

DICT-2.1 (the `LintelKit` types) depends on none of the **[0.2]** values, only on the shape above. *Owner
decision 1 (2026-11-19):* DICT-2.1 may start before the DICT-0.2 probes; the probes must be done before
DICT-2.2, which is the first story that uses their values.

## Consequences

- Later DICT pull requests are reviewed against the trust table and the contract here; a difference is a change
  to this ADR first.
- Dictation gains a path where the model deletes spoken words on purpose. The rules in Decision 2 and the raw
  text bound it; the regression set of the decision-7 work must prove the "wrong version kept" failure is gone.
- No baseline means the epic's value is judged by the dogfood numbers and the owner's own use, not by a
  measured improvement.

## Result of the version 2 change (2026-11-19)

`CleanupPrompt.version` is 2 and `FormatterGuard` is adjusted as Decision 2 requires. Numbers come from the
synthetic corpus (79 cases, 38 of them withdrawals, 21 negatives), both built-in catalog models, greedy
decoding, on an Apple silicon Mac. "Pass" means the output keeps the `must_keep` words and drops the
`must_drop` words. The version 1 prompt was run with the final guard, so the rows differ only by the prompt.
This table replaces the earlier ones: after the first and second review of PR #134 the prompt's examples were
rewritten (they had been corpus cases) and the guard was rewritten twice, so every number was measured again.

| Model | Prompt | Pass, all (79) | Pass, withdrawals (38) | Pass, negatives (21) | Kept withdrawn | Kept withdrawn and lost final | Fell back to raw | `known_bad` text returned | Negatives that lost a `must_keep` word |
|---|---|---|---|---|---|---|---|---|---|
| Qwen3 4B Instruct 2507 Q4_K_M | v1 | 52 | 14 | 19 | 24 | 1 | 1 | 1 | 2 (`en-neg-7`, `pl-neg-10`) |
| Qwen3 4B Instruct 2507 Q4_K_M | v2 | 71 | 32 | 20 | 4 | 0 | 4 | 0 | 1 (`en-neg-7`) |
| Qwen3 30B-A3B Instruct 2507 Q4_K_M | v1 | 49 | 12 | 19 | 27 | 0 | 0 | 1 | 2 (`pl-neg-10`, `pl-neg-12`) |
| Qwen3 30B-A3B Instruct 2507 Q4_K_M | v2 | 69 | 30 | 21 | 6 | 0 | 3 | 0 | 0 |

- "Kept withdrawn" and "lost final" are counted on answers the model gave and the guard accepted, not on raw
  fallbacks. `known_bad` texts are reported on their own and never counted as passes.
- The acceptance rule of Decision 2 holds for both models on this corpus with version 2: no case ends with the
  retracted version kept and the final one lost. This time it is also a property of the guard and not only of
  the model's output (see "The guard"): such an output is rejected whatever the model does, and the cases in
  which the guard can still accept a text with the withdrawn version are those that keep BOTH versions.
- Version 1 did keep the wrong version on this corpus (24 and 27 cases keep a withdrawn word; on 4B one of them
  also lost the final version). Version 2 reduces that to 4 and 6 cases, which keep both versions (the safe
  failure).
- The stricter guard costs a few more raw fallbacks than the first measurement (4B: 4, 30B: 3; they were 2 and
  1): a fallback is the safe outcome, the raw text is pasted. Pass counts moved by one or two cases against the
  earlier table because of that and of model variation.
- Over-removal is the risk that remains: on 4B one negative loses a word of the text (`en-neg-7`: a marker word
  used as content, "I mean what …"). Version 1 does the same there, so the prompt did not cause it. On 30B
  version 2 loses none. The guard cannot see it when the model deletes exactly the words before a marker.
- The prompt's examples are no longer corpus cases (the first version of this change used nine that were
  verbatim or close paraphrases). `CleanupPromptCorpusSeparationTests` fails when an example or a quoted sample of
  the system prompt shares three consecutive words, once markers and fillers are removed, or content-word
  Jaccard of 0.3 or more with a corpus text. The examples still teach the same shapes, so the corpus is not
  independent of the prompt in general.
- The corpus is small (79 cases, single sentences of 5 to 15 words, written by the same hand that wrote the
  marker list). The numbers describe this corpus; the owner's own phrasing and 40 to 60 word chunks may do
  worse. The prompt grows from about 1 900 to about 4 000 characters; the per-chunk latency of version 2 is not
  yet measured (`docs/perf.md`).

**The guard.** The lower bound 0.6 stays for a chunk without a marker or filler from the closed lists
(`retractionMarkers`, `fillers`). For a chunk with one, the bound is `min(0.6 x input words, input words -
allowance)`, never below 0.3 x input words (`FormatterGuard.lowerBound`); the allowance is the words of every
filler and marker plus 8 (`retractedSpanCap`) per marker. A filler therefore does not lower the bound of a
60-word chunk, and one retraction lowers it by at most about ten words however long the chunk is. Below 0.6, or
whenever a marker has words after it, the output must be derivable from the input at a cost of at most
`max(2, ceil(0.1 x output words))` edits (`FormatterGuard.derivationCost`). Free removals are a filler phrase,
an immediate repetition (up to four words), a stutter, and a span that ENDS in a marker (the retracted words
before it and the marker itself) when the retracted part is at most `min(words after the marker up to the next
marker + 2, 8)`. Everything else costs one per word.

**The replacement rule.** The words after the end of the LAST marker are the replacement. Each of them can only
be matched, removed as a filler, an immediate repetition or a stutter, replaced by a near form of itself
(`isNearForm`: equal after folding case and diacritics, or a shared prefix of at least four letters that is at
least 60% of the shorter word; "Marka" for "Mark", not "Nowak" for "Nowicki"), or absorbed by a digit whose
value EQUALS the number words it replaces (`NumberWords`: Polish and English cardinals and ordinals by stem or
word, 0 to 999 999, "25 000" read as one number, anything it cannot parse is not a number). A replacement
word is never deleted and never replaced by an unrelated word or by a digit of another value. This holds for
every chunk with a marker, relaxed or not. It is what rejects "Spotkanie jest o dziesiątej w sali
konferencyjnej." and "Potrzebujemy 50 sztuk." (the withdrawn version kept, the final one lost), which the
first version of this guard let through. The output must also end on the input's last word that is not a
filler or marker (or a near form of it, or digits equal to the number words the input ends on), else the
reason is `endChanged`, and a relaxed chunk may add at most 20% novel words. Any chunk of at least five words
is rejected as `addedContent` when more than 50% of its output words are not in the input. The 1.15 upper
bound, `answered` and `languageChanged` are unchanged. With the old guard 28 of the 79 `expected` texts were
rejected; with this one 0 are. `GuardReplacementTests` rejects every corpus `known_bad` that loses the final
version, the digit forms of the withdrawn-version outputs, and, for every contiguous deletion from every
withdrawing case that falls under 0.6 (what `main` rejected as too short), requires that the replacement is
still in the output.

**What the guard still cannot see.** A negated imperative used as content, "napisz Piotrkowi nie czekaj na
mnie z kolacją" → "Na mnie z kolacją.": the output keeps the words after the last marker, so a cut that ends
in the marker's neighbourhood can pass; only the prompt (keep both versions when unsure) and the raw text
protect the user. An output that keeps BOTH versions (three corpus `known_bad` texts, listed in
`GuardReplacementTests`): nothing is lost, and the guard cannot tell which one the speaker meant. A wrong but
plausible replacement inside the same word stem ("Marka" for "Mark"). A spoken number the parser does not know
(a year read as "twenty twenty-five") is not absorbed by digits and falls back to the raw text.

**Condition.** Version 2 is safe on both catalog models on this corpus. Should a smaller model be added to the
catalog, it must pass the same report before it may use version 2; until then the choice is the model's, not a
size limit.

