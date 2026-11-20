# ADR 0010: Context-aware dictation (trust model, frozen contract, reference phrases)

- Status: **Accepted** (owner decision of 2026-11-19: the DICT-0.1 gate is passed and the epic starts). Until
  the DICT-0.2 probes are run, the points marked **[0.2]** are working values, not decisions.
- Date: 2026-11-19; amended 2026-11-20 (the owner-accepted auto-learn amendment is applied below, see "Amendment of 2026-11-20 (applied)")
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
- **Amendment of 2026-11-20 (applied in this file).** The owner accepted the changes recorded in
  `0010-dictation-context-amendment-auto-learn.md` (auto-learn and context on by default; decisions P1–P13, U1–U14,
  K1–K4, Z1–Z10, O1–O9, DP1–DP9). They are written into this text without a new decision: where a rule, a table
  row or a section below carries the amendment, it says so. The amendment file stays as the historical record of
  how the decisions were reached; this file is the text in force. Spec:
  `.ai/specs/2026-11-20-dictation-vocabulary-auto-learn.md`. Approved vocabulary terms to a provider: ADR 0013.

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

1. **Each switch stops its own reads (amendment, change 2).** `plugins.dictation.contextEnabled` is on by default
   (P5.2). When it is `false` the port is never called for the snapshot at the shortcut press, and the clipboard
   and the file system are not read either, whatever `clipboardReference` and `fileReferences` say. The
   switches are separate (Z3): `contextEnabled = false` does not stop auto-learn, and the auto-learn switch
   `plugins.dictation.suggestFromCorrections` (on by default) stops the reads after a paste and does not stop
   context. A source that is not in `contextSources` is not in the request.
2. **The snapshot lives in memory for one dictation.** It is cleared on paste, on cancel and on error. Nothing
   from it is written to a log, `ranking.sqlite`, `dictation.sqlite`, a crash report or diagnostics. Field
   lengths are not logged either. The exceptions are what dictation stores today or by rule 5: the bundle id
   and the profile name (`app_profile`); and the **auto-learn exceptions (amendment, change 1)**. Auto-learn
   adds a second, separate read after the paste: a baseline read with a field handle, and a final read when the
   field loses focus, after 60 s or at the next dictation; two reads only. A selection is read on the user's
   command. Both texts live in memory until the comparison ends and are cleared on every exit path. Three
   things may be written, all in tables of the encrypted `dictation.sqlite`: (a) a candidate below the threshold
   as a keyed digest (HMAC) with a counter and two dates; (b) a ready suggestion in readable form: the heard
   forms, the corrected word, a counter, two dates and a fragment of the sentence around the correction; (c) a
   rejected pair as a keyed digest. The whole value of the field, text outside the fragment, the window title
   and the application identifier stay unwritten. The fragment is at most 80 characters and comes only from the
   pasted text, after the correction, one per suggestion (Z4). The same holds for every other source: the clipboard content, file
   names and paths from the listing, the terms of the user dictionary, and the dictated text itself (raw,
   cleaned, or with a resolved reference inserted) never reach a log, a crash report or diagnostics. Logs carry
   source names, durations, skip reasons and error codes only.
3. **The snapshot is used by Swift rules only.** It is not part of any LLM prompt in Phases 0 to 3. One
   exception (amendment, change 9): the built-in local model may review an auto-learn suggestion (P12.2 = B); it
   sees the pair alone, without the sentence fragment, and its verdict may only hold a suggestion back (Z7).
   **Everything a reference resolves to is inserted by Swift and never passes through a formatter:** the
   clipboard text, a file path found on disk, the path behind "ten plik". The formatter, and the continuity
   block built from the previous chunk, see spoken words only. DICT-3.4 and DICT-3.5 need the same test as
   DICT-3.1 criterion 4 (a recording formatter that receives no resolved content).
4. **Dictation context never goes to an external provider.** This holds in every phase and for every provider
   (Claude and any later one), and also for "My server". The owner switched external providers on for the
   product (decision 1 of 2026-11-19); for dictation that covers the dictated transcript only, after the user's
   consent. The snapshot, the clipboard content and file names are never added to a request that leaves the
   process. Changing this rule needs a new ADR. **The user dictionary is the one change, made by the new ADR
   this rule demands: `0013-approved-vocabulary-terms-to-providers.md` (Accepted, 2026-11-20).** By the owner's
   answer to Z6, narrowed by the answers to DP1–DP4 and DP8, the correct spelling of approved vocabulary terms
   goes to Claude with meeting notes written through Claude Code, and by no other route: not through an API key,
   not to other providers, not with dictation, not to the built-in model, not to "My server", and not while
   Dictation is off. Unapproved suggestions, candidates, rejected pairs and sentence fragments are in no request
   that leaves the process, sync included.
5. **History stores names of sources, never content.** `dictation_entry.context_sources` holds values from a
   closed list: `vocabulary`, `profile`, `field`, `selection`, `window`, `terminal`, `clipboard`, `files`.
6. **A failed read is "no context", never a failed dictation.** Recording and the HUD start without waiting
   for the snapshot.

A name that may confuse: `CleanupPrompt` already has a `<context>` block. That block is the end of the previous
paragraph of the same dictation, used for continuity. It is dictated text, not the snapshot, and it follows the
rules of the transcript.

### Trust table

This table is the single source for the Context pane's fixed table (there is no consent sheet, see "Consent") and the website text (DICT-2.4). Amendment: it gains the `corrections` row, and the `field`, `selection`, `window`, `terminal`, `clipboard` and `vocabulary` rows change as written here (changes 3 and 13).

| Source | When it is read | Limit | Where it goes | How long it lives | Hard refusals |
|---|---|---|---|---|---|
| Application (bundle id, pid) | At the shortcut press, when `contextEnabled` or `appProfiles` is on | One identifier | Profile rules; the profile name goes to history (`app_profile`) | Bundle id as today in history; pid in memory for one dictation | None (the bundle id is already read today for history) |
| `window`: title and document of the focused window | At every shortcut press (CTX-4 = A, on by default) | One title, one document URL | Nothing in Phases 0 to 3 uses it yet; the document may serve "ten plik" (**[0.2]**) | Memory, one dictation | No Accessibility grant; application on the denied list; Lintel's own windows; **in terminals neither the title nor the document address is read** (O2, DP6; "terminals" is the closed list of the auto-learn category "terminals"; a terminal built into a code editor or a browser is a known limitation). Whether the document attribute is reliable: **[0.2]** |
| `field`: kind of the focused field, text before and after the caret | At the shortcut press | 2 characters before and 1 after by default (CTX-1 = B), read by range; 500 and 200 stay the largest values a request may ask for. "Never the whole value" holds for the snapshot at the shortcut press only; the `corrections` row reads the whole value | Insertion rules use at most the last two characters before the caret and the first one after it | Memory, one dictation | Secure text field; Secure Event Input active; no grant; denied application; Lintel's own windows; time limit |
| `selection`: selected text | At every shortcut press (CTX-2 = A) and on the user's command "Add correction to vocabulary" | 2000 characters | Nothing in Phases 0 to 3 uses it yet; the fixed table in Settings says so ("nothing uses it for now"). CTX-2 = A is an owner decision, risk accepted, against the author's recommendation (C) | Memory, one dictation | Same as `field` |
| `terminal`: foreground process name and working directory | **Nothing until the probes** (answer to DP5, decision O1): the implementation reads neither the process name nor the directory. After successful probes (below) both switch on by themselves, at the shortcut press in a terminal, without another decision | One process name, one path | Profile `agentCLI`, root folder for file lookup | Memory, one dictation | Source off; a process of another user; no certain match of the active tab (**[0.2]**); `ssh` and `tmux` give no directory |
| `clipboard`: text of the clipboard | Only when the user spoke a clipboard phrase as a whole segment and `clipboardReference` is on (CTX-3 = A: on by default **only after a clean DICT-3.1 measurement**, any false paste keeps it off by default, O5; a confirmation in the HUD for the first 5 uses) | 20 000 characters of text; or, for "ten plik" with `clipboardReference` and `fileReferences` both on, exactly one file URL | Pasted verbatim by Swift into the result (for a file URL: the path in the target's syntax). The formatter never sees the content or the marker | Not kept. History stores the marker `⟦schowek⟧` | Setting off; concealed or transient marker types; content that is neither text nor exactly one file URL; over the limit; `accessBehavior` other than "always allow" (**[0.2]**) |
| `files`: file names under the terminal's working directory | Only when the user spoke a file trigger and `fileReferences` and `terminal` are on (nothing until the probes; after successful probes on by default, O1) | Depth 8, 50 000 entries, 20 results, time limit | One verified relative path, inserted by Swift after formatting | Listing cache in memory until the dictation ends. The pasted path is dictated content and stays in history | A place macOS protects with a privacy prompt without Full Disk Access (checked before any file-system call); `node_modules`, `.git`, `.build`, `DerivedData`; remote terminal |
| `vocabulary`: the user's own terms | After formatting | The user's file | Deterministic replacement in Swift. The correct spelling of approved terms only, to Claude with meeting notes written through Claude Code, after its consent window, while Dictation is on: scope in ADR 0013 | `Plugins/dictation/vocabulary.json` (0600) until the user removes it or erases the data | None. Terms are not logged |
| `corrections` (amendment, change 3): the whole value of the field after a pasted dictation, and the selection on the user's command | After every pasted dictation while `suggestFromCorrections` is on (it is on by default), and on the user's command | The whole value up to 100 000 characters; pasted text up to 12 000 characters (Z5); two reads, at most 60 s | An in-memory comparison; then the pair (for a ready suggestion also the fragment) to the suggestions tables, never to a request that leaves the Mac | Memory for the watch; on disk as in rule 2 | Secure field; Secure Event Input; no grant; Lintel's own windows; the auto-learn exclusion list (terminals, remote desktops and virtual machines, password managers); time limit |

Known limit, stated to the user: a web page can build a password field from an ordinary text field. Lintel
cannot detect that. The text of a field is never stored and never sent, which bounds the damage.

### Consent

- No new system grant: the read uses the Accessibility grant dictation already declares. The purpose is new.
- **Amendment (change 4): no in-app consent sheet, no one-time window, no onboarding step, also when the user
  turns context on again (O3).** The switch `plugins.dictation.suggestFromCorrections` defaults to `true`, also on
  existing installs after an update, so a user who granted Accessibility for pasting gets the field read without
  being asked. Context is on by default too (P5.2). The information is the Accessibility row in Settings →
  Permissions, the switch with its description in the Vocabulary section, and a fixed table in Settings →
  Dictation → Context that says what is read, when, and that nothing is stored, with a row for the selection. The
  table is shown whether context is on or off; the sentence under it says that history keeps the names of the
  sources used and never their text (answer to DP9). Once the terminal sources switch on after successful
  probes, the table needs rows for the process name, the working directory and the files; DICT-2.4 must say so.
  Before the probes the table has **no "Terminal" row** (R1: it would describe a read that does not exist).
  The owner's approval of each weaker default is a comment of the owner in the pull request that adds the key
  (Z10; `BACKWARD_COMPATIBILITY.md` section 3). For the terminal sources (the process name, the working
  directory, the file references) the approval is given in advance by the answer to DP5, recorded in this ADR.
- Each source has its own switch (Z3). The defaults are the ones in "What dictation context reads by default"
  below (change 13), no longer "all off by default" (D-Q6, D-Q14 reversed as written there).
- The Accessibility row in Settings → Permissions names **four** purposes: pasting, moving windows, reading the
  text field while dictating (the third also names the document address and says that in terminals the title and
  the address are not read), and reading the text field after a paste to notice the user's corrections, with
  where to switch it off. A change of a permission's purpose text needs a release note
  (`BACKWARD_COMPATIBILITY.md` sections 4 and 5). Mock-up v3 was accepted by the owner (2026-11-20), with three
  text changes the owner confirmed (R4).
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

**Auto-learn exclusion list (amendment, change 6).** Auto-learn has its own exclusion list, which the user edits,
pre-filled with three categories: terminals, remote desktops and virtual machines (Z2, Z9), password managers.
Browsers are **not** excluded. Each category is a closed list of bundle identifiers, each checked on an
installed copy; an identifier that cannot be confirmed is dropped, as below. The list is **separate** from
`contextDeniedApps` (Z2), which keeps the default above (password managers), so context reads in terminals,
remote desktops and virtual machines.

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
types **and the additive watch shape of change 7 (below, "Change 7 in detail")**, DICT-3.3 adds `FileNameLookup`.
`snapshot` may also be called on the user's command, for the selection. Reading the whole value (P4 = B) does not
change the shape. No other shape is allowed without changing this ADR first.

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

### Change 7 in detail: the contract shape for "until the field loses focus" (P2 = D)

The frozen shape has one call, `snapshot`, and no identity of the field. A watch that ends when the field
loses focus needs three things the shape lacks: the identity of the field (the final read must be of the same
element, also after focus has left it), a re-read of the same field, and a notification that focus left, with a
time limit.

Proposed shape. Additive only; every new member has a default, so `NoFocusContextReader` and every existing
implementation compile unchanged and answer `unsupported`.

```swift
/// Opaque handle to the field a snapshot was read from. Holds no text and is never stored.
/// The port keeps the element and the absolute range it read until `release` or its own time limit.
public struct FocusFieldHandle: Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64)
}

/// Open set, like `SkipReason`.
public struct FocusLossReason: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String)
    public static let focusMoved, applicationChanged, timeout, cancelled, unsupported: FocusLossReason
}

public struct FieldRereadRequest: Equatable, Sendable {
    public var slackCharacters: Int   // how far the range may have grown; default 200
    public var maxCharacters: Int     // hard cap of the returned text
    public var budget: Duration       // default 250 ms
    public init(slackCharacters: Int = 200, maxCharacters: Int, budget: Duration = .milliseconds(250))
}

public struct FieldReread: Equatable, Sendable {
    public var text: String?          // nil when skipped
    public var skipped: SkipReason?
    public init(text: String? = nil, skipped: SkipReason? = nil)
}

// FocusContextRequest, new member with a default:
//   keepsFieldHandle: Bool = false
// FocusContext, new member with a default:
//   fieldHandle: FocusFieldHandle? = nil
// FocusContextReader, new requirements with default implementations in a protocol extension:
//   func reread(_ handle: FocusFieldHandle, _ request: FieldRereadRequest) async -> FieldReread   // default: skipped == .unsupported
//   func focusLoss(of handle: FocusFieldHandle, within limit: Duration) async -> FocusLossReason  // default: .unsupported
//   func release(_ handle: FocusFieldHandle) async                                                // default: nothing
```

Notes on the shape:

- It follows the rule ADR 0010 already uses for probe-dependent members: each is optional and may stay
  unsupported, so a negative probe result changes behaviour, not the shape.
- **The whole value (P4 = B) fits this shape.** The baseline read is `snapshot` with the `field` source,
  `keepsFieldHandle = true` and both caret limits set to the cap of the watch, so it covers the whole field
  when the field is within the cap. `reread` then returns the whole value, at most `maxCharacters`. A field
  longer than the cap is not watched. The implementation reads the value in one call instead of by range;
  DICT-2.2 criterion 4 ("not by fetching the whole value") is about the context snapshot and gets an exception
  for the watch.
- Whether a focus notification is reliable, and whether an element can be read after it lost focus, is
  **[0.2]** (criteria 9 and 10 below). The numbers `slackCharacters` and the handle's own time limit are
  working values.
- A secure field never yields a handle. `reread` checks the secure state and Secure Event Input again and
  answers `secureField`.
- The implementation keeps the DICT-2.2 rules: `AXIsProcessTrusted()`, one serial queue per pid, a time limit
  per call, no attribute written to another application, invisible Unicode characters removed.
- **Timing.** The owner chose P2 = D on 2026-11-20, before DICT-2.1 started, so this shape goes into the
  DICT-2.1 contract pull request once this text is accepted (K1 closed).

### Limits

| Limit | Value | State |
|---|---|---|
| Text before the caret | 2 characters by default (CTX-1 = B); 500 is the largest a request may ask for | decided |
| Text after the caret | 1 character by default (CTX-1 = B); 200 is the largest a request may ask for | decided |
| Selection | 2000 characters | decided |
| Whole snapshot | 250 ms, then dictation runs without context; `snapshot` returns within 300 ms | decided as a budget, not measured |
| One Accessibility call | 250 ms working value (the `messagingTimeout` `AXWindowClient` uses today) | **[0.2]**: the probe gives the real return time with a stopped main thread and the recommended value |
| Clipboard reference | 20 000 characters, text only | decided |
| File lookup | depth 8, 50 000 entries; over either the result is empty. Results are cut at `limit`, at most 20 | decided |
| Watch length (amendment, change 8) | 60 s, ending earlier when the field loses focus or at the next dictation | decided (P2 = D) |
| Reads per watch | two (a baseline and a final one) | decided |
| Threshold of a suggestion | 2 corrections | decided (U13.1) |
| Longest candidate | 64 characters and 3 words | decided |
| Candidates kept | 30 days | decided (P8) |
| Longest pasted text that is watched | 12 000 characters | decided (Z5) |
| Cap of the field value | 100 000 characters; a longer field is not watched | decided (Z5); probe criterion 8 still measures it **[0.2]** |
| Sentence fragment | at most 80 characters, from the pasted text, one per suggestion | decided (Z4) |
| Learning data caps | 200 candidates, 50 suggestions, 5000 rejected digests | decided (Z9) |
| The port's own limit for holding a field handle | working value | **[0.2]** (probe criteria 9 and 10) |
| Paste warning for agent CLIs | over 800 characters or 3 lines; the text is not shortened | **[0.2]**: the probe checks where each tool folds a paste |

### Terminal: when the context is certain

Working rule, **[0.2]** as a whole (probe criteria 3 and 6):

- the frontmost application is a known terminal (Terminal, iTerm2, Ghostty in the probe);
- exactly one tab can be matched to a foreground process group and its working directory. Any doubt gives
  `terminal == nil` and `skipped[.terminal] == .unsupported`;
- `ssh` or `tmux` in the foreground gives `isRemote == true` and no directory, so file references are off for
  that dictation;
- a process of another user gives `nil`, without an error.

**Defaults and "successful probes" (amendment, change 13; owner decision O1, answer to DP5).** `TerminalContext`
keeps both fields of the frozen contract (the process name and the working directory); until the probes the
implementation reads neither (reading the directory and dropping it does not meet decision O1). After successful
probes the process name, the working directory and the file references switch on by default by themselves, without
another decision of the owner (owner decision, risk accepted); D-Q14 is then reversed in full. "Successful probes"
is a hard criterion: **the right terminal tab in all test cases and zero wrong directories. On any error nothing
switches on and the decision returns to the owner.** The list of test cases is part of story DICT-0.2 (R3), made
of probe criteria 3 and 6. The decision of 2026-11-20, recorded here, is the approval that Z10 demands for the
pull request that switches these three defaults on, provided the probe results in that pull request meet the
criterion.

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
| Probe criteria 7 to 12 (read after a paste, the whole value, focus notification, an element that lost focus, terminals, browsers and Electron, a stopped main thread during a watch; table below) | DICT-0.2 | the watch (spec steps B1 and B2), not DICT-2.2 |
| The DICT-3.1 measurement (0 false substitutions in the 60 phrases) | DICT-3.1 | the release; the clipboard reference is on by default only after a clean measurement (O5) |

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

## Amendment of 2026-11-20 (applied)

Written into this file from `0010-dictation-context-amendment-auto-learn.md`, which the owner accepted on 2026-11-20. The text below is the amendment's own, without a new decision. Where the amendment says "this file", "this ADR" or "the first version", read the amendment file. Every example is invented. No text comes from a real dictation.

### What changed since the first version of the amendment

The first version (PR #176) assumed the model of ADR 0010: off by default, an in-app consent sheet, a read by
range, nothing from the field on disk except a pair. The owner decided otherwise on 2026-11-20. The decisions
that go against the author's recommendation are recorded as **owner decisions, risk accepted (fields are read
without an indicator and without a per-feature consent)**:

| Decision | What the owner chose | ADR 0010 text it reverses |
|---|---|---|
| P5.1 | Auto-learn is **on by default for everyone, also after an update**; no consent sheet, no one-time window; the information is in the Permissions description and in Settings only | Consent: "an in-app consent sheet, shown every time the user turns the switch on, also on existing installs. Nothing appears by itself (D-Q1, D-Q2)" |
| P5.2 | **Dictation context is on by default too** | Rule 1: `contextEnabled = false` (the default); D-Q1 |
| P3 | **All applications** except an editable exclusion list (pre-filled: terminals, remote desktops, password managers); browsers work | — (ADR 0010 has one denied list, password managers only) |
| P4 | The **whole value of the field** is read | Trust table, `field`: "read by range, never the whole value" |
| P6 | The pair, a counter, two dates **and a fragment of the sentence** are stored; the fragment only for ready suggestions; candidates below the threshold as a keyed digest | Rule 2: nothing from the snapshot is written |
| P11.3 | **No sign** while a field is being watched | — (new) |
| P12 | A local model may review suggestions; **approved vocabulary terms may go to an external provider** the user turned on (scope narrowed to the minimum by DP1–DP4 and DP8: row Z6) | Rule 3 (Swift rules only); rule 4 (the user dictionary never leaves the process) |
| Z1, CTX-2 = A | The **selection** (up to 2000 characters) is read **at every dictation**. Author's recommendation, noted: C (read only on the command "Add correction to vocabulary") | Trust table, `selection`: "the source stays out of the default list until a rule needs it"; D-Q1 |
| Z1, CTX-3 = A | The **clipboard reference is on by default**, with a confirmation in the HUD for the first 5 uses. Author's recommendation, noted: B (off until the DICT-3.1 measurement). **The DICT-3.1 measurement must be done before the release.** Narrowed by decision O5: on by default only after a clean measurement. | Consent: "the clipboard and file references each have their own switch, all off by default (D-Q6)" |
| Z1, CTX-4 = A | The **window title and the document address** are read at every dictation. Author's recommendation, noted: C (off until a rule uses them). Narrowed by decision O2 and the answer to DP6: in terminals neither the window title nor the document address is read. | D-Q1 |
| Z6 | Approved terms go to the provider with **meeting notes (Claude)** and to **"My server"**. **Narrowed the same day to the minimum (answers to DP1–DP4 and DP8), which is in force:** only the correct spelling of approved terms, only with meeting notes written through Claude Code; not through an API key, not to other providers, not with dictation, not to the built-in model, **not to "My server"**; nothing while Dictation is off; every extension is a separate decision of the owner | Rule 4, through the new ADR 0013 that rule 4 demands |

The other answers to Z1 follow the author's recommendation or are not against it: CTX-1 = B (the field read for
context is 2 characters before the caret and 1 after), CTX-5/6 = the foreground process name only; the working
directory and files after the probes (decision O1: after successful probes they switch on by themselves).
The answer to DP5 narrows this: the process name waits for the probes too, and "successful probes" has a hard
criterion (below). Z2 and Z3: separate exclusion lists and separate switches. Z4, Z5, Z7,
Z8, Z9 and Z10: as the author recommended.

The full threat model, with the residual risks stated plainly, is in the spec (section "Model zagrożeń").

### The other decisions this amendment relies on

P1 = A+B (watching the field after the paste, plus the command "Add correction to vocabulary" on a selection).
P2 = D (until the field loses focus, at most 60 s, also ending at the next dictation) with two reads, no
listening. P7 = B (new tables in the encrypted `dictation.sqlite`). P8: candidates 30 days, suggestions until
the user decides, silence is not a rejection. P9 = A (rejected pairs as a keyed digest, for ever, exactly that
pair). P10: switching off deletes the candidates and stops a running watch at once, without a final read;
"Erase Learning Data…" deletes candidates, suggestions and rejected pairs; "Clear History" does not touch them.
P11.1, .2, .4: a fourth purpose in the Accessibility row, a `corrections` row in the trust table, "learning
data" rows with numbers. P13: synthetic data only, QA on a fake reader, numbers only in diagnostics. Threshold
2 (U13.1). K2: history does not record that a dictation was watched. K3: the variant "only inside Lintel's own
windows" is removed. K4: the digest key is a sub-key of the shared dictation key. The hard refusals are
confirmed: secure fields, Secure Event Input, Lintel's own windows, the exclusion list, no Accessibility grant,
nothing in logs.

### Change 11 in detail: probe criteria added to DICT-0.2

The probe script prints types, lengths and times, never content, and the test fields hold synthetic text.

| # | Criterion | Fills in |
|---|---|---|
| 7 | For the 12 applications of criterion 1: after a paste of synthetic text, read the field again after 0.2 s, 1 s and 5 s. Table "application × the pasted text is in the read", and the time after which the value is current (20 runs). Also the focus race: move focus to another field 0, 50 and 200 ms after the paste and record whether the baseline read comes from the pasted field and whether the anchor check notices. | delay of the first read; the list of applications where learning works |
| 8 | Fields with 1 000, 10 000 and 100 000 characters of synthetic text: read the **whole value** after the paste and again through the kept reference with the caret moved elsewhere. Table "application × length × read time × the value is complete and current" (20 runs). | the cap of the field value and of the pasted text (Z5); the budget |
| 9 | An observer of focused-element changes: move focus to another field, another window and another application. Table "application × notification arrived", its delay, and false notifications in 20 runs. | whether the chosen P2 = D works |
| 10 | An element that lost focus: read its value through the kept reference; also after the window was closed (an error is expected, a hang is not); also a field that became secure, and Secure Event Input switched on, between the two reads: `reread` answers `secureField`. | the `reread` shape |
| 11 | Repeat 7 to 10 in a terminal, in a browser (plain field, `contenteditable`, a password field built from a plain field) and in an Electron application; record how much text a terminal read returns, and whether any window attribute tells a private browser window from a normal one. | private windows and Electron (the choice of applications is decided in P3) |
| 12 | An application with a stopped main thread during a watch: the return time of the re-read, and that the pid queue does not block other processes. | the per-call limit and the budget |

Thresholds (confirmed by decision O9): an application counts as supported when criteria 7 and 8
pass in 20 of 20 runs for a field at the working cap; the watch is built when criteria 9 and 10 pass in at
least 8 of the 12 applications. Otherwise the new members stay `unsupported` and the owner decides again (P2 =
D and P4 = B were chosen before the probes).

### Residual risks the owner accepted

Stated here so that the accepted ADR carries them; the spec's threat model has the detail.

1. In every application outside the exclusion list, browsers included, the whole value of the field the user
   dictated into is in Lintel's memory for up to 60 s after each dictation. That value often holds text the
   user did not dictate and text written by other people. A password field a web page builds from an ordinary
   field cannot be detected.
2. A user who updates, and who granted Accessibility for pasting only, gets these reads without a question and
   without a message. They can learn of it from the Permissions description, the Vocabulary section and the
   release note.
3. There is no sign while a field is being watched.
4. A word corrected twice becomes a readable suggestion with a fragment of the sentence, stored until the user
   decides. Names of people are suggested on purpose.
5. The whole vocabulary of approved terms (the correct spelling of every entry, no heard forms) reaches Claude
   with meeting notes written through Claude Code once the user turns that provider on (ADR 0013; decision
   O6, narrowed by DP1–DP4 and DP8). Every such request carries the whole vocabulary, not only the terms that
   match the meeting. Nothing goes by any other route, and nothing while Dictation is off.
6. Erasing the learning data is not cryptographic (the key is shared with history) and does not reach backups.

From the answer to Z1 (context read by default, without an in-app consent). Points 7 to 9 go against the
author's recommendation:

7. At every press of the dictation shortcut the selected text (up to 2000 characters) is read into memory,
   although no rule in Phases 0 to 3 uses it. It can be text other people wrote, or a secret selected in a
   terminal.
8. At every press the window title and the document address are read into memory, although no rule in Phases
   0 to 3 uses them. A title often holds a message subject, a file name or a correspondent; in a terminal often
   the working directory or the running command, which is why in terminals neither the title nor the document
   address is read (decision O2; answer to DP6). Known limitation: a terminal built into a code editor or a
   browser is not on the list of terminals, so there the title and the address are read.
9. The clipboard reference is on by default only after a clean DICT-3.1 measurement; any false paste in the
   measurement keeps it off by default (decision O5). After a clean measurement the risk remains: a wrongly
   recognised phrase pastes the clipboard content (up to 20 000 characters) into the target application, which
   cannot be undone; after the first 5 uses there is no delay to cancel. A clean measurement on 60 phrases does
   not rule out a false recognition for a user with another voice, microphone or noise.
10. A user who updates, and who granted Accessibility for pasting only, gets all of these reads at every
    dictation without a question.
11. The foreground process name in a terminal is not read until the probes (answer to DP5). After successful
    probes it is read by default, on the tab-matching rule the probes tested.
12. The exclusion list for auto-learn (terminals, remote desktops and virtual machines, password managers) does
    not apply to context: context reads in terminals, remote desktops and virtual machines.

From the decisions on O1–O9, risk accepted:

13. After successful probes the working directory of the terminal and the file references switch on by default
    by themselves, for everyone, also after an update, without another decision of the owner and without a
    question to the user (decision O1). From that release on, every press of the shortcut in a terminal reads
    the path of the working directory (paths often hold client and project names), and a spoken file trigger
    lists file names under it from disk; the process name switches on with them (answer to DP5). The only
    gate is the probes. Their pass criterion is hard: the right terminal tab in all test cases and zero wrong
    directories; on any error the decision returns to the owner. The owner's approval is given in advance (it
    meets Z10), so no further comment of the owner precedes the switch. A tab matched wrongly outside the test
    cases gives the process name and the directory of another tab.
14. There is no consent sheet when context is turned on again either (decision O3). The information is the
    fixed table in Settings, which only a user who opens the pane sees.

What bounds them: the hard refusals (secure fields, Secure Event Input, Lintel's own windows), which cannot be
switched off; the exclusion list; the switch in the Vocabulary section, which deletes the candidates and stops
a running watch at once; two reads and 60 s; the threshold of 2 with keyed digests below it; the 30-day
retention of candidates; approval by the user before anything enters the vocabulary; the encrypted store. For
context: its own switch and per-source switches; `contextDeniedApps`; the field read cut to 3 characters; the
snapshot in memory for one dictation only, never in a log, on disk or in a request that leaves the process; the
HUD confirmation for the first 5 clipboard uses; the clipboard reference on by default only after a clean
measurement (O5); no window title and no document address in terminals (O2, DP6); no process name, no working
directory and no file listing until the probes (after probes that meet the hard criterion they switch on by
themselves, O1 and DP5); the fixed table in Settings (O3). For the vocabulary: one recipient and one route
(Claude, meeting notes through Claude Code), correct spellings only, nothing while Dictation is off (ADR 0013).

### What this amendment does not change

- Rule 6 (a failed read is "no context", never a failed dictation): a failed watch is "no learning".
- Rule 5 and the history format.
- Decision 2 (what the cleanup model may do) and the reference phrases.
- The denial of secure fields, of Secure Event Input and of Lintel's own windows, and the rule that Lintel
  never writes an attribute to another application or sets `AXManualAccessibility` (D-Q9).
- The vocabulary itself: `vocabulary.json`, `TermReplacer` and the panel rules of DICT-1.2. An approved
  suggestion is saved through the same rules and the same store.
- Rule 4 for the snapshot, the clipboard content and file names. Rule 4 for the user dictionary is changed by
  ADR 0013, not by this file.

### The owner's answers to Z1–Z10 (2026-11-20)

| # | Point | The owner's answer |
|---|---|---|
| Z1 | What context reads by default, per source (change 13) | CTX-1 field = B (2 characters before, 1 after). CTX-2 selection = A (at every dictation). CTX-3 clipboard = A (on, a confirmation in the HUD for the first 5 uses). CTX-4 window = A (title and document address). CTX-5/6 terminal and files = the process name only; the working directory and files after the probes (narrowed by DP5: the process name waits for the probes too). CTX-2, CTX-3 and CTX-4: owner decisions, risk accepted, against the author's recommendation. |
| Z2 | One exclusion list or two (change 6) | Separate lists. Auto-learn: terminals, remote desktops and virtual machines, password managers. |
| Z3 | Whether switching context off switches auto-learn off (change 2) | Separate switches. |
| Z4 | The sentence fragment (change 1) | As recommended: at most 80 characters, from the pasted text. |
| Z5 | The caps (changes 3 and 8) | As recommended: 12 000 / 100 000 characters. |
| Z6 | Approved terms to a provider (change 9) | Approved terms go to the provider with meeting notes (Claude) and to "My server". Needs a new ADR (rule 4): 0013, Accepted. **Narrowed the same day (DP1–DP4, DP8): only notes through Claude Code, correct spellings only, not "My server".** |
| Z7 | The local model (change 9) | As recommended: it sees the pair alone and may only hold a suggestion back. |
| Z8 | The sidebar count member (outside this ADR) | As recommended: a separate contract pull request. |
| Z9 | Small gaps | As recommended: 200 / 50 / 5000; heard forms grouped; virtual machines included. |
| Z10 | Approval of the weaker defaults | As recommended: a comment of the owner in the pull requests that add the keys. For the terminal sources the answer to DP5 is that approval, given in advance. |

### The owner's decisions on O1–O9 (2026-11-20)

Recorded as given. O1, O2, O3, O5 and O6 are the owner's decisions. O4, O7, O8 and O9 are **technical decisions
accepted as the spec author recommended** (the owner deferred to the author).

| # | Point | Decision |
|---|---|---|
| O1 | "The process name only": the contract, and what "after the probes" means | `TerminalContext` keeps **both fields** (the process name and the working directory); the request gets no new member. The working directory is **empty until the probes**: the implementation does not read it (reading it and dropping it does not meet the decision). **After successful probes the working directory and the file references switch on by default by themselves, without another decision.** Owner decision, risk accepted. Completed by the answer to DP5: the process name waits for the probes too; the hard criterion of "successful probes"; approval in advance. |
| O2 | The window title of a terminal | **In terminals the window title is not read.** Narrows CTX-4 = A. Completed by the answer to DP6: the document address is not read there either. |
| O3 | A consent sheet for context | **No consent sheet, also when context is turned on again.** A **fixed table in Settings** says what is read, when, and that nothing is stored, **with a row for the selection** (this meets the trust table's demand for `selection`). |
| O4 | Defaults of `appProfiles` and `smartInsertion` | Technical decision, as the author recommended: the backlog values stay (`appProfiles = false`, D-Q5; `smartInsertion = true`, active only while context is on). **Confirmed by the owner (answer to DP7, 2026-11-20): `smartInsertion` on, `appProfiles` off.** |
| O5 | The clipboard default if the DICT-3.1 measurement fails | **Any false paste in the measurement: the clipboard reference is off by default** (DICT-3.6 criterion 3 stays). **On by default only after a clean measurement.** |
| O6 | The scope of sending approved terms | **The whole vocabulary of approved terms (the correct spelling) goes to Claude with notes; "My server" the same in notes tasks; quality gate G is repeated after the prompt change.** Heard forms: a proposal with variants. **Narrowed by the answers to DP1–DP4 and DP8: no heard forms; "My server" gets no terms; only notes through Claude Code.** Details in ADR 0013. |
| O7 | How terms get from dictation to meeting notes | Technical decision, as the author recommended: an **additive port in `LintelKit`**, one item in the contract queue. |
| O8 | The meetings vocabulary (MEET-5.2) | Technical decision, as the author recommended: **unchanged**; it stays on the "Never" list of the providers spec. The difference is intended. |
| O9 | Probe thresholds | Technical decision, as the author recommended: the proposed thresholds stand (supported: 20 of 20; start of step B1: 8 of 12 applications). |

### The owner's answers to DP1–DP9 (2026-11-20)

Recorded as given. With these answers the amendment and ADR 0013 were accepted.

| # | Point | The owner's answer |
|---|---|---|
| DP1 | Whether heard forms go to the provider | No. The correct spelling only. |
| DP2 | "My server" | No. "My server" writes no notes and gets no vocabulary term in any request. |
| DP3 | An API key, later providers, dictation through a provider | No. Only meeting notes written through Claude Code. |
| DP4 | Whether the built-in model gets the terms | No. |
| DP5 | The terminal probes | **Approval in advance, with a hard criterion.** "Successful probes" means: the right terminal tab in all test cases and zero wrong directories. On any error the decision returns to the owner. The process name waits for the probes too. This decision is the approval Z10 demands, and it is recorded in this ADR (change 13). |
| DP6 | What "terminal" covers in O2 | As proposed: the document address is not read in terminals either; "terminals" is the same closed list of bundle identifiers as the auto-learn exclusion category; a terminal built into a code editor (or a browser) is a **known limitation**: the title and the address are read there. |
| DP7 | The defaults of O4 | **Confirmed:** `smartInsertion` on, `appProfiles` off. |
| DP8 | Terms while Dictation is off | They are not sent. |
| DP9 | The wording of the fixed table | As proposed: the sentence under the table is enough (history keeps the names of the sources used, never their text). The table is in Dictation → Context. |

DP1–DP4 and DP8 together are "the minimum"; every extension of it is a separate decision of the owner
(ADR 0013).

### What dictation context reads by default (change 13, summary)

The text of change 13 of the amendment is applied in the trust table, in "Consent", in "Terminal: when the context is certain" and in the answers above. Summary: `field` 2 characters before the caret and 1 after (CTX-1 = B); `selection` at every dictation, up to 2000 characters (CTX-2 = A); the clipboard reference on with a confirmation in the HUD for the first 5 uses, **on by default only after a clean DICT-3.1 measurement** (CTX-3 = A, O5; reverses D-Q6); `window`: title and document address (CTX-4 = A), **except in terminals, where neither is read** (O2, DP6); `terminal`: nothing until the probes, then the process name, the working directory and the file references on by default (O1, DP5; reverses D-Q14 in full). `smartInsertion = true` and `appProfiles = false` (DP7). CTX-2, CTX-3 and CTX-4 are owner decisions, risk accepted, against the author's recommendation (C, B and C). **The DICT-3.1 measurement (0 false substitutions in the 60 phrases) must be done before the release.** The rule that no snapshot, clipboard content or file name goes into a request that leaves the process (rule 4) is unchanged.

