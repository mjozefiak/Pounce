# ADR 0010, proposed amendment: learning vocabulary terms from corrections (auto-learn) and context on by default

- Status: **Proposed** (until the owner accepts this text). The owner's decisions of 2026-11-20 on auto-learn
  (P1–P13, U1–U14, K1–K4, threshold 2) and the owner's answers of the same day to **Z1–Z10** (what dictation
  context reads by default, and the nine points that waited for a confirmation) are applied below. Three answers
  (CTX-2 = A, CTX-3 = A, CTX-4 = A) go against the author's recommendation and are recorded as owner decisions,
  risk accepted; the recommendation stays visible as noted. What the answers leave open is listed at the end
  (O1–O9) and is not resolved here. ADR 0010
  (`0010-dictation-context.md`) stays **Accepted and unchanged**: its status, its rules and its frozen contract
  are exactly as they were. This file is a separate proposal so that the accepted text is not edited before the
  owner accepts the wording.
- Date: 2026-11-20 (revised the same day after the owner's three sets of decisions, and again after the answers
  to Z1–Z10)
- Spec: `.ai/specs/2026-11-20-dictation-vocabulary-auto-learn.md` (decision tables, the owner's answers to
  Z1–Z10, the open points O1–O9, the threat model). Backlog: story DICT-2.8 in
  `.ai/specs/backlog/2026-11-13-epic-context-aware-dictation.md`. Providers:
  `.ai/specs/2026-11-10-external-ai-providers.md` (approved vocabulary terms as a new kind of data).
- Why a file and not a new number: the amendment changes rules of ADR 0010; it is merged into ADR 0010 when
  accepted, and this file is then removed or marked as applied. One exception has its own number: rule 4
  says "Changing this rule needs a new ADR", and the owner confirmed that (Z6). The draft is
  `0013-approved-vocabulary-terms-to-providers.md` (status Proposed). This file changes rule 4 only by pointing
  to it (change 9).
- Every example is invented. No text comes from a real dictation.

## What changed since the first version of this proposal

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
| P12 | A local model may review suggestions; **approved vocabulary terms may go to an external provider** the user turned on | Rule 3 (Swift rules only); rule 4 (the user dictionary never leaves the process) |
| Z1, CTX-2 = A | The **selection** (up to 2000 characters) is read **at every dictation**. Author's recommendation, noted: C (read only on the command "Add correction to vocabulary") | Trust table, `selection`: "the source stays out of the default list until a rule needs it"; D-Q1 |
| Z1, CTX-3 = A | The **clipboard reference is on by default**, with a confirmation in the HUD for the first 5 uses. Author's recommendation, noted: B (off until the DICT-3.1 measurement). **The DICT-3.1 measurement must be done before the release.** | Consent: "the clipboard and file references each have their own switch, all off by default (D-Q6)" |
| Z1, CTX-4 = A | The **window title and the document address** are read at every dictation. Author's recommendation, noted: C (off until a rule uses them) | D-Q1 |
| Z6 | Approved terms go to the provider with **meeting notes (Claude)** and to **"My server"** | Rule 4, through the new ADR 0013 that rule 4 demands |

The other answers to Z1 follow the author's recommendation or are not against it: CTX-1 = B (the field read for
context is 2 characters before the caret and 1 after), CTX-5/6 = the foreground process name only; the working
directory and files after the probes. Z2 and Z3: separate exclusion lists and separate switches. Z4, Z5, Z7,
Z8, Z9 and Z10: as the author recommended.

The full threat model, with the residual risks stated plainly, is in the spec (section "Model zagrożeń").

## The other decisions this amendment relies on

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

## The 13 changes

| # | ADR 0010 text | Change (form fixed by the owner's decisions) | Still to confirm |
|---|---|---|---|
| 1 | Rule 2 (the snapshot lives in memory for one dictation; nothing from it is written) | A second, separate read after the paste: a baseline read with a field handle, and a final read when the field loses focus, after 60 s or at the next dictation; two reads only. A selection read on the user's command. Both texts live in memory until the comparison ends and are cleared on every exit path. **The exceptions to the no-write rule:** (a) a candidate below the threshold as a keyed digest (HMAC) with a counter and two dates; (b) a ready suggestion in readable form: the heard forms, the corrected word, a counter, two dates and a fragment of the sentence around the correction; (c) a rejected pair as a keyed digest. All in tables of the encrypted `dictation.sqlite`. The whole value of the field, text outside the fragment, the window title and the application identifier stay unwritten. The fragment is at most 80 characters and comes only from the pasted text, after the correction, one per suggestion (Z4). | — |
| 2 | Rule 1 (off means nothing is read; `contextEnabled = false` is the default) | The default of `contextEnabled` becomes `true` (P5.2). The sentence "off means nothing is read" must be rewritten so that it stays true: each switch stops its own reads. The switches are separate (Z3): `contextEnabled = false` stops the reads at the shortcut press and does not stop auto-learn; the auto-learn switch stops the reads after a paste and does not stop context. The default list of sources is in change 13 (Z1). | Wording of the rewritten rule 1 |
| 3 | Trust table | New row `corrections`: read after every pasted dictation while the switch is on (it is on by default) and on the user's command; limit: the whole value of the field up to a cap, two reads, at most 60 s; goes to an in-memory comparison, then the pair (and for a ready suggestion the fragment) to the suggestions tables, never to a request that leaves the Mac; lives in memory for the watch, on disk as in change 1; hard refusals as today plus the exclusion list. The `field` row: "never the whole value" holds for the snapshot at the shortcut press only. The `selection` row gains "on the user's command". The `vocabulary` row gains "to an external provider the user turned on, after its consent window" (change 9). The table feeds the Context pane and the website, so both change. Caps: 12 000 characters of pasted text, 100 000 characters of the field value (Z5). The `field` row for the snapshot: 2 characters before the caret and 1 after by default (CTX-1 = B). The `selection`, `window`, `terminal` and `clipboard` rows change as in change 13. The `vocabulary` row points to ADR 0013 for the scope (Z6). | Probe criterion 8 still measures the 100 000 cap |
| 4 | Consent | Reversed for auto-learn: **no in-app consent sheet**, no one-time window, no onboarding step. The switch `plugins.dictation.suggestFromCorrections` defaults to `true`, also on existing installs after an update, so a user who granted Accessibility for pasting gets the field read without being asked. The information is the Accessibility row in Settings → Permissions, the switch with its description in the Vocabulary section, and the trust table. For context: on by default (P5.2), with the sources of change 13. The owner's approval of each weaker default is a comment of the owner in the pull request that adds the key (Z10; `BACKWARD_COMPATIBILITY.md` section 3). | Whether a sheet is still shown when the user turns context on again: the answer to Z1 does not say (O3) |
| 5 | Consent, the Accessibility row in Settings → Permissions (three purposes) | Four purposes. The fourth says in plain words that Lintel reads the text field after it pasted a dictation, to notice the user's corrections, and where to switch it off. DICT-2.4 criterion 4 names three and must follow. A change of a permission's purpose text needs a release note (`BACKWARD_COMPATIBILITY.md` sections 4 and 5). | Wording, with the prototype |
| 6 | Default denied applications (`contextDeniedApps`) | Auto-learn has an exclusion list the user edits, pre-filled with three categories: terminals, remote desktops, password managers. Browsers are **not** excluded. Each category is a closed list of bundle identifiers, each checked on an installed copy; an identifier that cannot be confirmed is dropped, as today. The list is **separate** from `contextDeniedApps` (Z2) and the category "remote desktops" includes virtual machines (Z2, Z9). `contextDeniedApps` keeps its ADR 0010 default (password managers), so context reads in terminals, remote desktops and virtual machines. | — |
| 7 | Decision 3 (the frozen contract) | The additive shape in "Change 7 in detail" (field handle, re-read of the same field, focus-loss notification), every member with a default, **written into ADR 0010 before the DICT-2.1 pull request**; plus the statement that `snapshot` may be called on the user's command for the selection. Reading the whole value (P4 = B) does not change the shape. | Exact signatures, frozen by the accepted text |
| 8 | Limits table | New rows: watch length 60 s; two reads per watch; threshold 2; longest candidate 64 characters and 3 words; candidates kept 30 days; the port's own limit for holding a field handle. Working values: longest pasted text that is watched 12 000 characters; cap of the field value 100 000 characters (**[0.2]**, probe criterion 8); fragment at most 80 characters; 200 candidates, 50 suggestions, 5000 rejected digests. These are the owner's answers (Z4, Z5, Z9), no longer working values. The rows "Text before the caret" and "Text after the caret" get the default of the context snapshot: 2 and 1 (CTX-1 = B); 500 and 200 stay the largest values a request may ask for. | — |
| 9 | Rules 3 and 4 (Swift rules only; nothing to an external provider) | Rule 3 gains one exception: the built-in local model may review a suggestion (P12.2 = B); it sees the pair alone, without the sentence fragment, and its verdict may only hold a suggestion back (Z7). Rule 4 is **not edited here**: as it demands, the change is a new ADR, `0013-approved-vocabulary-terms-to-providers.md` (Proposed). By the owner's answer to Z6, approved vocabulary terms go to the provider with meeting notes (Claude) and to "My server"; unapproved suggestions, candidates, rejected pairs and sentence fragments are in no request that leaves the process, sync included. The snapshot, the clipboard content and file names stay under rule 4 unchanged. When ADR 0013 is accepted, rule 4 gets a pointer to it. | Acceptance of ADR 0013; its open points (O6–O8) |
| 10 | Rule 5 (`context_sources` in history, a closed list) | **No change** (K2: history does not record that a dictation was watched). | — |
| 11 | Open points and the **[0.2]** marks | New probe criteria 7 to 12 (below) and their rows in the "Open points" table; they block the watch (spec steps B1 and B2), not DICT-2.2. | Thresholds, confirmed with this text |
| 12 | Outside this ADR | `BACKWARD_COMPATIBILITY.md` (section 1 for the contract members; section 2 for the new tables; section 3 for the keys and the weaker defaults; sections 4 and 5 for the purpose text, the release note and the list shortcuts), the Dictation row of `AGENTS.md`, the backlog (DICT-2.3 and DICT-2.4 rewritten for the new defaults, DICT-0.2 criteria, story DICT-2.8), `docs/perf.md`, `docs/qa.md`, the providers spec. The sidebar count (U9 = B) is a member of the main window contract (ADR 0008), not of this ADR. | — |
| 13 | D-Q1, and depending on Z1 also D-Q6 and D-Q14 ("each has its own switch, all off by default") | Context is on by default (P5.2). **What it reads by default (the owner's answer to Z1):** `field`: 2 characters before the caret and 1 after (CTX-1 = B); `selection`: at every dictation, up to 2000 characters (CTX-2 = A); the clipboard reference: on, with a confirmation in the HUD for the first 5 uses (CTX-3 = A; reverses D-Q6); `window`: the title and the document address (CTX-4 = A); `terminal`: the foreground process name only (reverses D-Q14 for the name); the working directory and files after the probes. CTX-2, CTX-3 and CTX-4 are owner decisions, risk accepted, against the author's recommendation (C, B and C), which stays noted in the spec. **The DICT-3.1 measurement (0 false substitutions in the 60 phrases) must be done before the release.** The "Consent" sentence "each has its own switch, all off by default" is rewritten: the switches stay, the defaults change as above. | O1 (the process name alone in the contract and the probes), O2, O3, O4, O5 |

## Change 7 in detail: the contract shape for "until the field loses focus" (P2 = D)

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

## Change 11 in detail: probe criteria added to DICT-0.2

The probe script prints types, lengths and times, never content, and the test fields hold synthetic text.

| # | Criterion | Fills in |
|---|---|---|
| 7 | For the 12 applications of criterion 1: after a paste of synthetic text, read the field again after 0.2 s, 1 s and 5 s. Table "application × the pasted text is in the read", and the time after which the value is current (20 runs). Also the focus race: move focus to another field 0, 50 and 200 ms after the paste and record whether the baseline read comes from the pasted field and whether the anchor check notices. | delay of the first read; the list of applications where learning works |
| 8 | Fields with 1 000, 10 000 and 100 000 characters of synthetic text: read the **whole value** after the paste and again through the kept reference with the caret moved elsewhere. Table "application × length × read time × the value is complete and current" (20 runs). | the cap of the field value and of the pasted text (Z5); the budget |
| 9 | An observer of focused-element changes: move focus to another field, another window and another application. Table "application × notification arrived", its delay, and false notifications in 20 runs. | whether the chosen P2 = D works |
| 10 | An element that lost focus: read its value through the kept reference; also after the window was closed (an error is expected, a hang is not); also a field that became secure, and Secure Event Input switched on, between the two reads: `reread` answers `secureField`. | the `reread` shape |
| 11 | Repeat 7 to 10 in a terminal, in a browser (plain field, `contenteditable`, a password field built from a plain field) and in an Electron application; record how much text a terminal read returns, and whether any window attribute tells a private browser window from a normal one. | private windows and Electron (the choice of applications is decided in P3) |
| 12 | An application with a stopped main thread during a watch: the return time of the re-read, and that the pid queue does not block other processes. | the per-call limit and the budget |

Proposed thresholds (to confirm with this amendment): an application counts as supported when criteria 7 and 8
pass in 20 of 20 runs for a field at the working cap; the watch is built when criteria 9 and 10 pass in at
least 8 of the 12 applications. Otherwise the new members stay `unsupported` and the owner decides again (P2 =
D and P4 = B were chosen before the probes).

## Residual risks the owner accepted

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
5. Approved terms reach an external provider with meeting notes (Claude) once the user turns it on, and "My
   server" (ADR 0013).
6. Erasing the learning data is not cryptographic (the key is shared with history) and does not reach backups.

From the answer to Z1 (context read by default, without an in-app consent). Points 7 to 9 go against the
author's recommendation:

7. At every press of the dictation shortcut the selected text (up to 2000 characters) is read into memory,
   although no rule in Phases 0 to 3 uses it. It can be text other people wrote, or a secret selected in a
   terminal.
8. At every press the window title and the document address are read into memory, although no rule in Phases
   0 to 3 uses them. A title often holds a message subject, a file name or a correspondent; in a terminal often
   the working directory or the running command.
9. The clipboard reference is on before the false-recognition rate was measured. A wrongly recognised phrase
   pastes the clipboard content (up to 20 000 characters) into the target application, which cannot be undone;
   after the first 5 uses there is no delay to cancel. The DICT-3.1 measurement must be done before the release.
10. A user who updates, and who granted Accessibility for pasting only, gets all of these reads at every
    dictation without a question.
11. The foreground process name in a terminal is read by default, on a tab-matching rule that is still **[0.2]**.
12. The exclusion list for auto-learn (terminals, remote desktops and virtual machines, password managers) does
    not apply to context: context reads in terminals, remote desktops and virtual machines.

What bounds them: the hard refusals (secure fields, Secure Event Input, Lintel's own windows), which cannot be
switched off; the exclusion list; the switch in the Vocabulary section, which deletes the candidates and stops
a running watch at once; two reads and 60 s; the threshold of 2 with keyed digests below it; the 30-day
retention of candidates; approval by the user before anything enters the vocabulary; the encrypted store. For
context: its own switch and per-source switches; `contextDeniedApps`; the field read cut to 3 characters; the
snapshot in memory for one dictation only, never in a log, on disk or in a request that leaves the process; the
HUD confirmation for the first 5 clipboard uses; no working directory and no file listing until the probes.

## What this amendment does not change

- Rule 6 (a failed read is "no context", never a failed dictation): a failed watch is "no learning".
- Rule 5 and the history format.
- Decision 2 (what the cleanup model may do) and the reference phrases.
- The denial of secure fields, of Secure Event Input and of Lintel's own windows, and the rule that Lintel
  never writes an attribute to another application or sets `AXManualAccessibility` (D-Q9).
- The vocabulary itself: `vocabulary.json`, `TermReplacer` and the panel rules of DICT-1.2. An approved
  suggestion is saved through the same rules and the same store.
- Rule 4 for the snapshot, the clipboard content and file names. Rule 4 for the user dictionary is changed by
  ADR 0013, not by this file.

## The owner's answers to Z1–Z10 (2026-11-20)

| # | Point | The owner's answer |
|---|---|---|
| Z1 | What context reads by default, per source (change 13) | CTX-1 field = B (2 characters before, 1 after). CTX-2 selection = A (at every dictation). CTX-3 clipboard = A (on, a confirmation in the HUD for the first 5 uses). CTX-4 window = A (title and document address). CTX-5/6 terminal and files = the process name only; the working directory and files after the probes. CTX-2, CTX-3 and CTX-4: owner decisions, risk accepted, against the author's recommendation. |
| Z2 | One exclusion list or two (change 6) | Separate lists. Auto-learn: terminals, remote desktops and virtual machines, password managers. |
| Z3 | Whether switching context off switches auto-learn off (change 2) | Separate switches. |
| Z4 | The sentence fragment (change 1) | As recommended: at most 80 characters, from the pasted text. |
| Z5 | The caps (changes 3 and 8) | As recommended: 12 000 / 100 000 characters. |
| Z6 | Approved terms to a provider (change 9) | Approved terms go to the provider with meeting notes (Claude) and to "My server". Needs a new ADR (rule 4): draft 0013, Proposed. |
| Z7 | The local model (change 9) | As recommended: it sees the pair alone and may only hold a suggestion back. |
| Z8 | The sidebar count member (outside this ADR) | As recommended: a separate contract pull request. |
| Z9 | Small gaps | As recommended: 200 / 50 / 5000; heard forms grouped; virtual machines included. |
| Z10 | Approval of the weaker defaults | As recommended: a comment of the owner in the pull requests that add the keys. |

## Open after the answers (not resolved here)

The spec lists these as O1–O9 with their sources. None has a working value that may be built on.

| # | Point | Blocks |
|---|---|---|
| O1 | "The process name only": the frozen `TerminalContext` returns the process name and the working directory together and a request cannot ask for the name alone, so either the implementation must not read the directory until the probes pass or the request needs an additive member, written down before the DICT-2.1 pull request. The process name itself depends on the tab-matching rule, which is **[0.2]** (criteria 3 and 6); the answer does not say whether the name waits for the probes. "After the probes": whether the working directory and files then switch on by default or need another decision. | DICT-2.1, DICT-3.2 |
| O2 | CTX-4 = A reads the window title in terminals too, and a terminal's title often holds the working directory or the running command, which CTX-5 defers. | DICT-2.3 |
| O3 | Whether a consent sheet is still shown when the user turns context on again. And where the user is told that nothing uses the selection yet: the trust table demands that text "or the source stays out of the default list". | DICT-2.4 |
| O4 | The defaults of `appProfiles` (D-Q5) and `smartInsertion` with context on by default. | DICT-2.3, DICT-2.5 |
| O5 | What happens to the clipboard default if the DICT-3.1 measurement fails. DICT-3.6 criterion 3 says a single false paste keeps `clipboardReference` off by default; CTX-3 = A says on. | the release with DICT-3.1 |
| O6–O8 | The details of sending approved terms: see ADR 0013, "Open points". | any code that attaches terms |
| O9 | The probe thresholds of "Change 11 in detail" (20 of 20; 8 of 12) are still a proposal, confirmed with this text. | the probes |

Also still open, as gates and not as gaps: the acceptance of this text, of ADR 0013 and of mock-up v3 as the
prototype.
