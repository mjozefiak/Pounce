# ADR 0010, proposed amendment: learning vocabulary terms from corrections (auto-learn)

- Status: **Proposed**. Nothing here is decided. ADR 0010 (`0010-dictation-context.md`) stays **Accepted and
  unchanged**: its status, its rules and its frozen contract are exactly as they were. This file is a separate
  proposal so that the accepted text is not edited before the owner decides.
- Date: 2026-11-20
- Spec: `.ai/specs/2026-11-20-dictation-vocabulary-auto-learn.md` (the open decisions U1–U14 and P1–P13, with
  variants and recommendations). Backlog: story DICT-2.8 in
  `.ai/specs/backlog/2026-11-13-epic-context-aware-dictation.md`.
- Why a file and not a new number: the amendment changes rules of ADR 0010 and has no decision of its own; it
  is merged into ADR 0010 when accepted, and this file is then removed or marked as applied.
- Every example is invented. No text comes from a real dictation.

## How to read this file

Each of the 12 changes below names the text of ADR 0010 it touches, what would change, and **which owner
decision it depends on**. A change is applied only in the form its decisions select. Until the owner fills in
the decisions in the spec, no change is applied and no code may rely on any of them.

Decisions referred to (all open): **P1** how Lintel learns about a correction (A: watching the field after
the paste, B: explicit command, C: only inside Lintel's own windows), **P2** how long the watch lasts (A: until
the field loses focus with a time limit, B: one read after a fixed time, C: only at the next dictation, D: A
plus the next dictation), **P3** which applications, **P4** how much of the field is read, **P5** default
value and relation to `contextEnabled`, **P6** what is stored, **P7** where, **P8** for how long, **P9**
rejected pairs as a keyed digest or readable, **P10** switching off and erasing, **P11** what the user sees,
**P12** models and what never leaves the Mac, **P13** tests, QA and diagnostics. **U11** is the consent
sheet, **U12** the skip filters, **U13** the threshold.

## Why ADR 0010 has to change at all

Auto-learn by watching the field needs two things ADR 0010 forbids today:

1. a read of the text field **after the paste**, when the user is no longer dictating (ADR 0010 reads once,
   at the shortcut press);
2. a **write to disk** of something that comes from the field: the corrected word was typed by the user in
   another application (rule 2 says nothing from the snapshot is written).

With P1 = C (corrections inside Lintel's own windows only) neither is needed and **this amendment is not
needed either**.

## The 12 changes

| # | ADR 0010 text | Proposed change | Depends on | Not needed when |
|---|---|---|---|---|
| 1 | Rule 2 (the snapshot lives in memory for one dictation; nothing from it is written) | Add a second, separate read after the paste with its own lifetime, and the **only exception to the no-write rule**: the pair "heard → corrected", a counter and, if chosen, two dates, stored in the place P7 selects. The text of the field, the sentence around the correction and the window title stay unwritten. | P1, P2, P4, P6, P7 | P1 = C. With P1 = A and P2 = C there is no second read, but the write exception is still needed. With P1 = B the read is the selection, on the user's command, and only the write exception and change 3 apply. |
| 2 | Rule 1 (off means nothing is read) | With P5.2 = a (auto-learn obeys `contextEnabled`): no change. With P5.2 = b (independent switch): the rule is rewritten, because "context off" no longer means "nothing is read". | P5 | P5.2 = a; P1 = C |
| 3 | Trust table | New row `corrections`: when it is read, the limit, where it goes (the suggestions store, never a prompt), how long it lives, hard refusals. In the `field` row the "when" column is no longer only "at the shortcut press" (unless P2 = C). The table feeds the consent sheet, the Context pane and the website, so all three change. | P1, P2, P3, P4, P6, P7, P8 | P1 = C |
| 4 | Consent | A new switch (working name `plugins.dictation.suggestFromCorrections`, default from P5.1), a sheet when it is turned on (form and frequency from U11), and its relation to `contextEnabled`. | P5, U11 | P1 = C (a switch may still exist, without a consent to read other applications) |
| 5 | Consent, the Accessibility row in Settings → Permissions (three purposes) | Four purposes: the fourth is "checks the field after a paste for your corrections (when suggestions are on)". DICT-2.4 criterion 4 names three and must follow. A change of a permission's purpose text (`BACKWARD_COMPATIBILITY.md` sections 4 and 5, release note). | P1, P11.1 | P1 = C |
| 6 | Default denied applications (`contextDeniedApps`) | State whether the list applies to auto-learn, and add the categories P3 selects (terminals, browsers, remote desktops and virtual machines) as closed lists of bundle identifiers, each checked on an installed copy; an identifier that cannot be confirmed is dropped, as today. State whether auto-learn has its own list. | P3 | P1 = C |
| 7 | Decision 3 (the frozen contract) | With P2 = A or D: a new, additive shape (below), written here **before** the DICT-2.1 pull request, or a second contract pull request in the `LintelKit` queue. With P2 = B, or P1 = B: no new shape, but the ADR states that `snapshot` may be called outside the shortcut press and for which purpose. With P2 = C: no change. | P1, P2 | P1 = C; P2 = C |
| 8 | Limits table | New rows: length of the watch, longest pasted text that is watched, read size of the watch, longest candidate, suggestions per watch, the retention values of P8, the cap of rejected pairs (P9), and the port's own limit for holding a field handle. | P2, P4, P8, P9, U12, U13 | P1 = C (only the retention rows remain) |
| 9 | Rules 3 and 4 (Swift rules only; nothing to an external provider) | State in so many words that pairs, candidates and rejected pairs are in no prompt and never leave the process, sync included. With P12.2 = B (a built-in local model reviews a pair) rule 3 gains that one exception instead. | P12 | never: the sentence is worth adding in every variant |
| 10 | Rule 5 (`context_sources` in history, a closed list) | Decide whether history records that a dictation was watched (a new value on the closed list). Recommendation: no. Open question K2 in the spec. | owner (K2) | recommendation accepted |
| 11 | Open points and the **[0.2]** marks | New probe criteria 7 to 12 (below) and their rows in the "Open points" table; they block the watch (spec step B1 and B2), not DICT-2.2. | P1, P2, P4 | P1 = C |
| 12 | Outside this ADR | `BACKWARD_COMPATIBILITY.md` (section 1 with P2 = A/D; section 2 for the new file or tables; section 3 for the keys; sections 4 and 5 for the purpose text and the release note), the Dictation row of `AGENTS.md`, the backlog (DICT-2.4 criterion 4, DICT-0.2 criteria, story DICT-2.8), `docs/perf.md`, `docs/qa.md`. | every decision that adds a surface | — |

## Change 7 in detail: the contract shape for "until the field loses focus" (P2 = A or D)

The frozen shape has one call, `snapshot`, and no identity of the field. A watch that ends when the field
loses focus needs three things the shape lacks: the identity of the field (the final read must be of the same
element, also after focus has left it), a re-read of the **same absolute range** (after a correction the caret
is elsewhere, so "500 characters before the caret" no longer covers the pasted text; the port remembers the
range, the plugin never handles offsets in another application's field), and a notification that focus left,
with a time limit.

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
- Whether a focus notification is reliable, and whether an element can be read after it lost focus, is
  **[0.2]** (criteria 9 and 10 below). The numbers `slackCharacters` and the handle's own time limit are
  working values.
- A secure field never yields a handle. `reread` checks the secure state and Secure Event Input again and
  answers `secureField`.
- The implementation keeps the DICT-2.2 rules: `AXIsProcessTrusted()`, one serial queue per pid, a time limit
  per call, no attribute written to another application, invisible Unicode characters removed.
- **Timing.** If the owner chooses P2 = A or D before DICT-2.1 starts, this shape goes into the same contract
  pull request. If not, it is a second contract pull request after DICT-2.1, in the one queue with DICT-3.3
  and the MEET contract stories (open question K1 in the spec; the spec recommends not blocking DICT-2.1).

## Change 11 in detail: probe criteria added to DICT-0.2

The probe script prints types, lengths and times, never content, and the test fields hold synthetic text.

| # | Criterion | Fills in |
|---|---|---|
| 7 | For the 12 applications of criterion 1: after a paste of synthetic text, read the field again after 0.2 s, 1 s and 5 s. Table "application × the pasted text is in the read", and the time after which the value is current (20 runs). | delay of the first read; the list of applications where learning works |
| 8 | Same field with the caret moved elsewhere: read the remembered absolute range through the range attribute. Table "application × range read works / empty / error". | whether P4 = A is possible |
| 9 | An observer of focused-element changes: move focus to another field, another window and another application. Table "application × notification arrived", its delay, and false notifications in 20 runs. | whether P2 = A or D is possible |
| 10 | An element that lost focus: read its range through the kept reference; also after the window was closed (an error is expected, a hang is not). | the `reread` shape |
| 11 | Repeat 7 to 10 in a terminal, in a browser (plain field, `contenteditable`, a password field built from a plain field) and in an Electron application; record how much text a terminal read returns (whole buffer or the range). | decisions P3.1 and P3.2 |
| 12 | An application with a stopped main thread during a watch: the return time of the re-read, and that the pid queue does not block other processes. | the per-call limit and the budget |

Proposed thresholds (to confirm with this amendment): an application counts as supported when criteria 7 and 8
pass in 20 of 20 runs; the watch in the P2 = A or D form is built when criteria 9 and 10 pass in at least 8 of
the 12 applications. Otherwise the new members stay `unsupported` and the owner chooses again between P2 = B
and C.

## What this amendment does not change

- Rule 6 (a failed read is "no context", never a failed dictation): a failed watch is "no learning".
- Decision 2 (what the cleanup model may do) and the reference phrases.
- The denial of secure fields, of Secure Event Input and of Lintel's own windows, and the rule that Lintel
  never writes an attribute to another application.
- The vocabulary itself: `vocabulary.json`, `TermReplacer` and the panel rules of DICT-1.2. An approved
  suggestion is saved through the same rules and the same store.

## Which decision unlocks which change

| Decision | Changes it selects |
|---|---|
| P1 | whether 1, 3, 4, 5, 6, 7, 8 and 11 are needed at all (none with P1 = C) |
| P2 | 1 (second read), 3 ("when" column), 7 (contract shape), 8, 11 |
| P3 | 3, 6 |
| P4 | 1, 3, 8, 11 |
| P5 | 2, 4 |
| P6, P7 | 1 (what the write exception covers and where), 3, 12 |
| P8, P9 | 3, 8 |
| P10 | 3 ("how long it lives"), the consent text (4) |
| P11 | 3, 5 |
| P12 | 9 |
| P13 | none in the ADR; the QA and diagnostics rules live in the spec |
| U11, U12, U13 | 4, 8 |
| K1, K2 (spec) | timing of 7; 10 |
