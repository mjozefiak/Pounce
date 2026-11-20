# ADR 0013: Approved vocabulary terms may leave the process (meeting notes written through Claude Code only)

- Status: **Accepted** (owner's decision, 2026-11-20). Nothing here is implemented yet. The owner's decisions
  of 2026-11-20 on the open points O6 to O8 of the auto-learn spec and on the points DP1 to DP4 and DP8 are
  applied below. The scope is the **minimum** the owner chose; every extension of it is a separate decision of
  the owner (and a change of this ADR).
- Date: 2026-11-20
- **Amendment of 2026-11-20 (the owner fully accepted the provider-choice mock-up v2 the same day):** the owner
  replaced the provider's consent window with the choice of the provider in Settings (ADR 0011, amendment). Every
  place below that spoke of the consent window or the consent text version is rewritten to the actual state, and
  **one consequence is stated plainly and marked as a point for the owner's decision: a user who has already
  chosen Claude Code starts sending the vocabulary terms after the update with no new question** (see "Consequences
  and residual risks"). The scope of the data, the routes and the tests are unchanged.
- Why this ADR exists: ADR 0010 (`0010-dictation-context.md`, Accepted), rule 4, says that the user dictionary
  is never added to a request that leaves the process, and ends with "Changing this rule needs a new ADR". The
  owner decided on 2026-11-20 to change it (decision P12 and the answer to point Z6 of the auto-learn spec) and
  confirmed that a new ADR is required. This is that ADR. It changes rule 4 for one kind of data only.
- Number 0013: 0011 is the external-providers ADR and 0012 the distribution ADR on `main`; no open pull request
  adds an ADR with this number (checked 2026-11-20).
- Specs: `.ai/specs/2026-11-20-dictation-vocabulary-auto-learn.md` (decisions P12, Z6, Z7; the threat model),
  `.ai/specs/2026-11-10-external-ai-providers.md` (section "Nowy rodzaj danych: zatwierdzone terminy słownika").
  Related: `0010-dictation-context-amendment-auto-learn.md` (Accepted, change 9), ADR 0011 (providers; the choice of the provider is the consent from 2026-11-20).
- Every example is invented. No text comes from a real dictation or meeting.

## Context

The dictation vocabulary (`Plugins/dictation/vocabulary.json`) holds the words speech recognition gets wrong:
names of people, of clients, of projects and of products. Until now it never left the process: ADR 0010 rule 4
forbade it for every provider and for "My server", and the providers spec had the vocabulary on its "Never"
list.

Two things changed on 2026-11-20. Auto-learn (story DICT-2.8) lets the user approve suggested terms with one
click, so the vocabulary will grow faster. And the owner decided that approved terms may be used where notes
are written by a provider, so that the names in the notes are spelled the way the user spells them. The owner's
first answer (Z6, decision O6) also named "My server"; the same day the owner narrowed the scope to the minimum
below (answers to DP1 to DP4 and DP8). The narrower, later decision is the one in force.

## Decision

The scope in force (the owner's answer to Z6 and decision O6, narrowed by the owner's answers to DP1 to DP4
and DP8 on 2026-11-20), recorded as given:

1. **Only the correct spelling of approved vocabulary terms goes to Claude, and only with meeting notes
   written through Claude Code.** When the user has turned the Claude Code provider on for meeting notes and
   has chosen it in Settings (the choice is the consent), the request that carries the transcript may also carry the target spelling
   ("Save as") of the entries of the dictation vocabulary. Nothing else from the vocabulary goes: no heard
   forms (DP1 = A).
2. **Not by any other route.** Terms do **not** go: through an API key (also to the same recipient), to any
   other provider, with dictation (text cleanup or dictation through a provider), to the built-in model, or to
   "My server" (DP2, DP3, DP4). "My server" writes no notes; it gets no vocabulary term in any request, so for
   "My server" rule 4 of ADR 0010 stays as it was.
3. **Nothing goes while Dictation is off (DP8).** A Dictation plugin that is switched off contributes no terms,
   also when the vocabulary file exists.
4. **Every extension is a separate decision of the owner.** Heard forms, another route, another provider,
   another task, the built-in model or "My server" each need a new decision of the owner and a change of this
   ADR before any code.
5. **Suggestions and sentence fragments stay local.** Unapproved suggestions, candidates below the threshold,
   rejected pairs and sentence fragments of auto-learn are in no request that leaves the process: not to a
   provider, not to "My server", not to sync.
6. **Rule 4 of ADR 0010 is changed for the user dictionary only, and only for the route of point 1.** The
   snapshot (field text, selection, window title, document address, terminal process), the clipboard content
   and file names stay under rule 4 exactly as they are: they never leave the process.

"Approved" means: an entry of `vocabulary.json`. A suggestion the user approved becomes an ordinary entry and
cannot be told apart from one typed by hand, so the decision covers **the whole vocabulary**, including terms
the user typed before this change.

The other decisions of 2026-11-20, recorded as given:

7. **The whole vocabulary goes, as correct spellings (decision O6).** Every notes request through Claude Code
   carries the target spelling of every entry of `vocabulary.json`, not only the terms that match the
   transcript at hand.
8. **Quality gate G is repeated after the prompt change (decision O6).** Attaching terms changes the notes
   prompt (`whole1`), so it gets a new version, and the measurement of gate G is repeated before that version
   reaches users.
9. **The path is an additive port in `LintelKit` (decision O7, technical, as the spec author recommended).**
   `MeetingsPlugin` never imports `DictationPlugin`; the new member has a default (no terms) and is one item in
   the contract queue. A plugin that is off contributes nothing through the port (point 3).
10. **The meetings vocabulary (story MEET-5.2) is unchanged (decision O8, technical, as the spec author
    recommended).** It stays on the "Never" list of the providers spec. The difference is intended.

## What may leave the process, and what may not

| Data | Claude, meeting notes written through Claude Code | Every other route (API key, other providers, dictation, the built-in model, "My server") | Stays in the process |
|---|---|---|---|
| Approved terms of the dictation vocabulary: the target spelling of every entry (the whole vocabulary) | yes, once the provider (Claude Code) is chosen in Settings, while Dictation is on | never | — |
| Heard forms (variants) of vocabulary terms | never (DP1 = A) | never | yes |
| The meetings vocabulary (MEET-5.2) | never | never | yes |
| Unapproved suggestions (heard forms, corrected word, counter, dates) | never | never | yes |
| Sentence fragments of suggestions | never | never | yes |
| Candidates below the threshold and rejected pairs (keyed digests) | never | never | yes |
| The context snapshot, the clipboard content, file names (ADR 0010 rule 4) | never | never | yes |
| The value of a field read by auto-learn | never | never | yes, in memory for one watch |

The built-in model runs inside the Mac, so giving it terms would not be a send; the owner still decided that it
does not get them (DP4). Whether this answer also covers the local term list of the conditional dictation
cleanup story DICT-4.2 (built-in model, on the Mac, not a send) is open point R6 of the spec; it is not
answered here, and DICT-4.2 does not start until the owner answers.

## Conditions

- **Provider.** Terms are attached only inside `ProviderRunner.run`, behind the same authorization as the
  transcript (ADR 0011, decision 3). The notice shown when Claude Code is chosen, and its "Details", name the
  vocabulary terms among what leaves the Mac; the notice for the API-key route says that no vocabulary term goes
  there. **There is no consent window and no consent text version any more (owner, 2026-11-20), so adding this
  kind of data does not invalidate a choice made earlier.** *(Before the amendment: adding this kind of data
  changed the consent text version, a consent given earlier was no longer valid and the window was shown again.)*
  Returning to the local model ends the sending.
- **Gate G.** The notes prompt with terms is a new prompt version; the measurement of quality gate G is
  repeated on it before release (decision O6).
- **Dictation on.** Terms are attached only while the Dictation plugin is on (DP8).
- **One route.** The test "what leaves the Mac" of the providers spec keeps the vocabulary on the forbidden
  list for every route except notes through Claude Code, and keeps heard forms on it for every route.
- **Tests that must exist in the pull request that attaches terms:** a fixture with canary strings in a
  suggestion, a sentence fragment, a candidate and a rejected pair, none of which appears in the request; a canary in a
  heard form, which appears in no request; a test
  that no term is in the request when Claude Code is not the chosen provider; a test that no term is in a request
  through an API key, to "My server", in a dictation request or in the built-in model's prompt, and none while
  Dictation is off; a source scan that the auto-learn
  types are not imported by provider code or by a formatter that talks to a server.
- **Logs.** Terms are never logged (ADR 0010 rule 2 already says so); this does not change.

## Consequences and residual risks

Stated plainly, as the owner accepted them:

- Names of clients, colleagues, projects and products from the vocabulary reach an external company and fall
  under its retention rules. What was sent cannot be taken back.
- Every notes request carries the whole vocabulary (decision O6), so the provider receives client and project
  names also with a meeting they have nothing to do with, and holds the full list after the first request.
- A term approved with one click on a suggestion becomes data that is sent with the next meeting notes, also on
  automatic retries and on "Regenerate Notes" for older meetings.
- The decision covers terms typed by hand before this change, not only terms that came from auto-learn. A user
  who built a vocabulary under the old promise ("the dictionary never leaves") and had already chosen Claude Code for
  meeting notes **starts sending the terms after the update, with no new question and no window** (before the
  amendment the consent window was to tell them). Dictation must be on. **Point for the owner's decision:** whether
  to keep it so, or to use one of the undecided options of ADR 0011 (record an info version at choice time and
  suspend sending with an inline "Review" banner when the scope of data grows; a banner without suspension; or
  release notes only). Nothing is chosen here; until the owner decides, the behaviour is the one described.
- The website and the trust table say today that the vocabulary never leaves the process. Both must change with
  this ADR.

What bounds the risk: the provider is off by default and needs the choice of the provider, whose notice names the terms; nothing
unapproved and no heard form is ever sent; one recipient and one route only (Claude, notes through Claude
Code); nothing while Dictation is off; the user can remove a term, turn the provider off or erase the vocabulary; the
snapshot, the clipboard and file names stay local.

## Heard forms: variant A chosen (DP1)

An entry has a target spelling and heard forms: what speech recognition writes instead of it (invented
example: the form "kubernetis" for the term "Kubernetes"). The owner chose **A** on 2026-11-20. B and C stay
here as the record of what was not chosen; either would be an extension (point 4).

| Variant | What goes with notes | Gain | Cost and risk |
|---|---|---|---|
| **A** (**chosen**) | The target spelling of every term only | The least data; the model sees the list of correct names and matches distorted words itself | The model may fail to connect a badly distorted form with its term, and the name stays wrong in the notes |
| B (not chosen) | The target spelling, plus the forms of those terms whose form occurs in the transcript at hand | The model gets the pair "heard, correct" where it is needed | More data leaves: forms show how the user speaks and what recognition gets wrong; needs matching before the send; a new line in the consent window |
| C (not chosen) | The target spelling and all forms of all terms | The simplest to build; the best chance of a correct name | The most data in every request, also forms unrelated to the meeting; a longer prompt; a new line in the consent window |

## The owner's answers to DP1 to DP4 and DP8 (2026-11-20)

Recorded as given. Together they are "the minimum".

| # | Point | The owner's answer |
|---|---|---|
| DP1 | Whether heard forms are sent. | No. The correct spelling only (variant A). |
| DP2 | "My server". | No. "My server" writes no notes and gets no terms, in no request (dictation cleanup included). |
| DP3 | An API key, later providers, dictation through a provider. | No. Only notes through Claude Code. |
| DP4 | Whether the built-in model gets the terms. | No. |
| DP8 | Whether terms are sent when Dictation is off and the vocabulary file exists. | No. |

Every extension of this scope is a separate decision of the owner.

## What this ADR does not change

- ADR 0010 rules 1 to 3, 5 and 6, and rule 4 for everything except the user dictionary.
- ADR 0011: the gate (the chosen provider; formerly the consent), `ProviderRunner`, the isolation flag, the one-generation track.
- The vocabulary itself: `vocabulary.json`, `TermReplacer`, the panel rules of DICT-1.2.
- The local review of suggestions by the built-in model (auto-learn decision P12.2 and answer Z7): it runs on
  the Mac, sees the pair alone and is not a send. "My server" does not review suggestions.
- Rule 4 of ADR 0010 for "My server", the API-key route, other providers and dictation: the user dictionary
  does not go there.

## After acceptance

Accepted on 2026-11-20. ADR 0010 rule 4 gets one sentence pointing here when the accepted amendment is written
into ADR 0010 (spec point R5). The providers spec already describes this kind of data (section "Nowy rodzaj
danych: zatwierdzone terminy słownika"); its notice and "Details" text and test, the trust table, the website text and
`BACKWARD_COMPATIBILITY.md` follow in the pull requests that implement it.
