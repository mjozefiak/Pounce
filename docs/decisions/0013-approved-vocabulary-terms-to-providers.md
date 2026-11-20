# ADR 0013: Approved vocabulary terms may leave the process (meeting notes with a provider, "My server")

- Status: **Proposed** (draft, until the owner accepts this text). Nothing here is implemented, and no code may
  attach a vocabulary term to a request before this ADR is accepted and its open points have answers.
- Date: 2026-11-20
- Why this ADR exists: ADR 0010 (`0010-dictation-context.md`, Accepted), rule 4, says that the user dictionary
  is never added to a request that leaves the process, and ends with "Changing this rule needs a new ADR". The
  owner decided on 2026-11-20 to change it (decision P12 and the answer to point Z6 of the auto-learn spec) and
  confirmed that a new ADR is required. This is that ADR. It changes rule 4 for one kind of data only.
- Number 0013: 0011 is the external-providers ADR and 0012 the distribution ADR on `main`; no open pull request
  adds an ADR with this number (checked 2026-11-20).
- Specs: `.ai/specs/2026-11-20-dictation-vocabulary-auto-learn.md` (decisions P12, Z6, Z7; the threat model),
  `.ai/specs/2026-11-10-external-ai-providers.md` (section "Nowy rodzaj danych: zatwierdzone terminy słownika").
  Related: `0010-dictation-context-amendment-auto-learn.md` (Proposed, change 9), ADR 0011 (providers, consent).
- Every example is invented. No text comes from a real dictation or meeting.

## Context

The dictation vocabulary (`Plugins/dictation/vocabulary.json`) holds the words speech recognition gets wrong:
names of people, of clients, of projects and of products. Until now it never left the process: ADR 0010 rule 4
forbade it for every provider and for "My server", and the providers spec had the vocabulary on its "Never"
list.

Two things changed on 2026-11-20. Auto-learn (story DICT-2.8) lets the user approve suggested terms with one
click, so the vocabulary will grow faster. And the owner decided that approved terms may be used where notes
are written by a provider, so that the names in the notes are spelled the way the user spells them.

## Decision

The owner's answer to Z6, recorded as given:

1. **Approved vocabulary terms go to the provider with meeting notes (Claude).** When the user has turned the
   provider on for meeting notes and has accepted its consent window, the request that carries the transcript
   may also carry approved terms of the dictation vocabulary.
2. **Approved vocabulary terms go to "My server".** "My server" is the LLM server at a loopback address the
   user set up in Settings → Dictation. A request to it stays on the Mac and leaves the Lintel process, which is
   why rule 4 covered it.
3. **Suggestions and sentence fragments stay local.** Unapproved suggestions, candidates below the threshold,
   rejected pairs and sentence fragments of auto-learn are in no request that leaves the process: not to a
   provider, not to "My server", not to sync.
4. **Rule 4 of ADR 0010 is changed for the user dictionary only.** The snapshot (field text, selection, window
   title, document address, terminal process), the clipboard content and file names stay under rule 4 exactly
   as they are: they never leave the process.

"Approved" means: an entry of `vocabulary.json`. A suggestion the user approved becomes an ordinary entry and
cannot be told apart from one typed by hand, so the decision covers **the whole vocabulary**, including terms
the user typed before this change.

## What may leave the process, and what may not

| Data | Provider, meeting notes (Claude) | "My server" | Stays in the process |
|---|---|---|---|
| Approved terms of the dictation vocabulary | yes, after the provider's consent window | yes | — |
| Unapproved suggestions (heard forms, corrected word, counter, dates) | never | never | yes |
| Sentence fragments of suggestions | never | never | yes |
| Candidates below the threshold and rejected pairs (keyed digests) | never | never | yes |
| The context snapshot, the clipboard content, file names (ADR 0010 rule 4) | never | never | yes |
| The value of a field read by auto-learn | never | never | yes, in memory for one watch |

## Conditions

- **Provider.** Terms are attached only inside `ProviderRunner.run`, behind the same authorization as the
  transcript (ADR 0011, decision 3). Adding this kind of data changes the consent text, so its version changes
  and a consent given earlier is no longer valid: the window is shown again and names vocabulary terms among
  what leaves the Mac. Returning to the built-in model ends the sending.
- **No code before acceptance.** Until this ADR is accepted and the open points below have answers, the test
  "what leaves the Mac" of the providers spec keeps the vocabulary on the forbidden list.
- **Tests that must exist in the pull request that attaches terms:** a fixture with canary strings in a
  suggestion, a sentence fragment, a candidate and a rejected pair, none of which appears in the request; a test
  that no term is in the request without a consent of the current version; a source scan that the auto-learn
  types are not imported by provider code or by a formatter that talks to a server.
- **Logs.** Terms are never logged (ADR 0010 rule 2 already says so); this does not change.

## Consequences and residual risks

Stated plainly, as the owner accepted them:

- Names of clients, colleagues, projects and products from the vocabulary reach an external company and fall
  under its retention rules. What was sent cannot be taken back.
- A term approved with one click on a suggestion becomes data that is sent with the next meeting notes, also on
  automatic retries and on "Regenerate Notes" for older meetings.
- The decision covers terms typed by hand before this change, not only terms that came from auto-learn. A user
  who built a vocabulary under the old promise learns of the change from the provider's consent window.
- "My server" is on the same Mac, but Lintel does not control what that server does with a request (its logs,
  its own forwarding).
- The website and the trust table say today that the vocabulary never leaves the process. Both must change with
  this ADR.

What bounds the risk: the provider is off by default and needs a consent that names the terms; nothing
unapproved is ever sent; the user can remove a term, turn the provider off or erase the vocabulary; the
snapshot, the clipboard and file names stay local.

## Open points (not decided; none may be assumed)

The answer to Z6 names the recipients. It does not cover the points below. They are O6 to O8 of the auto-learn
spec.

| # | Point |
|---|---|
| 1 | The whole vocabulary in every request, or only the terms that match the transcript at hand. |
| 2 | Whether heard forms (variants) are sent, or only the target spelling. Until this is answered, the providers spec keeps heard forms on its "Never" list, as it keeps the whole vocabulary today; that is the current state, not a decision. |
| 3 | "My server": in which requests. Today the only request to it is dictation text cleanup; a term list in the cleanup prompt is the conditional story DICT-4.2, which waits for a measurement. And whether the user is told, or asked, before terms go to "My server". |
| 4 | Whether the decision also covers the second channel to the same recipient (an API key, providers Phase 2), later providers (Phase 3) and dictation through a provider (Phase 4). The answer names meeting notes and Claude. |
| 5 | Attaching terms changes the notes prompt (`whole1`), so it needs a new prompt version: whether the measurement of quality gate G must be repeated. |
| 6 | Whether the built-in notes model gets the terms too. That is not a send, and the answer does not mention it. |
| 7 | How terms get from the dictation vocabulary to meeting notes. The vocabulary belongs to `DictationPlugin`, notes to `MeetingsPlugin`, and plugins never import each other, so this needs a contribution through `LintelKit` (one more item in the contract queue) or another design. Also whether terms are sent when Dictation is off and the vocabulary file exists. |
| 8 | The meetings vocabulary (story MEET-5.2) stays on the "Never" list of the providers spec while the dictation vocabulary is sent with meeting notes. Whether that difference is intended. |

## What this ADR does not change

- ADR 0010 rules 1 to 3, 5 and 6, and rule 4 for everything except the user dictionary.
- ADR 0011: the consent gate, `ProviderRunner`, the isolation flag, the one-generation track.
- The vocabulary itself: `vocabulary.json`, `TermReplacer`, the panel rules of DICT-1.2.
- The local review of suggestions by the built-in model (auto-learn decision P12.2 and answer Z7): it runs on
  the Mac, sees the pair alone and is not a send. "My server" does not review suggestions.

## When accepted

Status becomes Accepted; ADR 0010 rule 4 gets one sentence pointing here; the providers spec, the trust table,
the website text and `BACKWARD_COMPATIBILITY.md` follow in the pull requests that implement it.
