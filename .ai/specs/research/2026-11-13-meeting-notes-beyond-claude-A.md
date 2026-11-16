# Surowy research: notatki ze spotkań, punkt odniesienia Claude (agent A, 2026-11-13)

> Materiał źródłowy do `.ai/specs/briefs/2026-11-13-meeting-notes-beyond-claude-A.md`. Zebrany przez subagentów (rynek, techniki), po angielsku, z adresami URL i datami. Część o Claude została niezależnie sprawdzona na trzech stronach Anthropic (CZĘŚĆ C). Oznaczenia [P]/[S]/UNVERIFIED pochodzą od autorów raportów.

---

# CZĘŚĆ A: rynek

## AI meeting-notes market research (benchmark: Claude)

Research date: 2026-11-13. Method: web search plus fetches of primary pages where reachable.

Conventions used below:

- **[P]** = read on a primary page in this session (vendor's own announcement, help center, pricing page, docs).
- **[S]** = secondary source only (press, reviews, vendor comparison blogs). Many of these are written by competitors; treat as leads.
- **UNVERIFIED** = I could not confirm it on a primary page, or sources conflict.
- **Inference** = my reading, not a sourced fact.

Access limits of this research: reddit.com is blocked for the search tool, so no Reddit thread was read directly; Reddit sentiment below comes from third-party summaries and is marked. help.openai.com returned 403. The RuntimeWire "Parka" article is paywalled after the intro.

---

### PART 1 — Claude (Anthropic)

#### 1.0 Bottom line

Anthropic **does** have a first-party meeting product as of this week: **Claude Meetings (beta)**. It is a **cloud bot that joins Google Meet as a visible participant**. It is **not** a local recorder, it is not on individual plans, and it does not capture system audio. A separate **Mac desktop recorder codenamed "Parka"** (system + microphone audio, no bot) was found in Claude Desktop code in August 2026; it is **unreleased and unconfirmed by Anthropic**.

#### 1.1 Claude Meetings (beta) — CONFIRMED

Sources:
- Anthropic product article "Introducing Claude Meetings", dated 2026-11-12: https://claude.com/resources/articles/claude-meetings [P]
- Help center "Use Claude Meetings": https://support.claude.com/en/articles/18325154-use-claude-meetings [P]
- Release notes entry dated 2026-11-12: https://support.claude.com/en/articles/12138966-release-notes [P]
- TechCrunch, 2026-11-10: https://techcrunch.com/2026/11/10/anthropic-launches-claude-meetings-to-turn-workplace-discussions-into-plans-and-tasks/ [S]
- VentureBeat, 2026-11-12: https://venturebeat.com/technology/anthropic-brings-claude-into-google-meet-to-draft-documents-and-whiteboards-during-your-meetings [S]

Date note: the press covered the announcement on 2026-11-10 (alongside Claude Whiteboards, Claude Sheets and Claude Data); Anthropic's article and the release note for the beta rollout are dated 2026-11-12.

| Field | What is confirmed | Source |
|---|---|---|
| What it does | Claude joins a video call "as a visible participant", takes notes, answers questions (asked aloud by saying "Claude", or typed in Meet chat; it answers in writing by default), and builds artifacts live (docs, whiteboards, slides). | [P] article, help center |
| Capture method | A bot participant in the call. No local or system-audio capture. | [P] |
| Platforms | **Google Meet only**. Other platforms "coming soon", none named. Managed from Claude (web) and Claude Desktop; mobile not mentioned. | [P] |
| Plans | **Team and Enterprise only**, beta. Team: on by default, an owner can turn it off. Enterprise: off until an owner enables it (for all, or by custom role). Not on Free/Pro/Max. | [P] help center |
| Excluded | Organizations with zero data retention, HIPAA-ready configuration or customer-managed encryption keys cannot use the beta. | [P] |
| Prerequisite | Google Calendar connector enabled by an owner; user picks a meeting and clicks "Add Claude". Per-user auto-join (all meetings, or all except one-on-ones); owners cannot set auto-join for users. | [P] |
| Duration limit | Up to **eight hours** per call; warns before leaving. | [P] help center |
| What is stored | "a transcript, summary, and screen descriptions, not audio". No audio playback. Stored on a per-meeting page in claude.ai (cloud). | [P] |
| Output | Meeting page with live transcript, notes with **summary and action items**, chat, and everything Claude built. Recap email to organization members on the invite. | [P] |
| Ask across past meetings | Yes: the Meetings calendar shows past meetings, and in a regular chat users can ask Claude about past meetings they have access to. | [P] help center |
| Consent / notice | Claude appears as a participant with a live tile and posts a notice in the call chat. Anthropic tells users to make sure everyone is OK with being transcribed. If the host declines admission, Claude does not retry. | [P] |
| External guests | Enterprise: internal only by default. If allowed, Claude takes notes, posts its notice, does not reply in chat; guests get no meeting page or recap. By default Claude leaves if an outsider (including another company's notetaker bot) joins. **Conflict in Anthropic's own pages for Team:** the launch article says Claude stays out by default; the help center lists external guests as allowed by default on Team. | [P] both pages; conflict also noted by https://vanja.io/claude-meetings/ [S] |
| Connected tools | Can use each person's connectors (example: send a Slack message) with that person's permission; for spoken requests it asks each time to confirm who is speaking. | [P] |
| Integrations | Sending transcripts to **Gong, Attention, Granola, Fireflies.ai, Otter and Plaud** is "coming soon" (not live). | [P] article |
| Pricing | During beta: notes, transcripts and answers without connected tools are included in Team/Enterprise. Artifacts made in meetings are free through **2027-02-10**; price afterwards not published. Connected-tool use counts toward plan usage. | [P] |
| Seat prices (context) | Team standard USD 20/seat/month annual (25 monthly); Enterprise USD 20/seat/month annual, 20-seat minimum, plus usage. | [S] VentureBeat 2026-11-12 |
| Languages | **Not stated anywhere** I read (article, help center, press). Polish support is UNVERIFIED. | — |
| Speaker identification in the transcript | **Not described.** The only related statement is the per-request speaker confirmation for tool use. UNVERIFIED how the transcript labels speakers (Inference: a Meet bot can read participant names, so per-participant labels are likely). | — |
| Retention period / deletion | **Not published** for meeting pages. | noted by vanja.io, lycore.com [S] |
| Model training | **Not stated** in the Meetings pages. General context: Team and Enterprise fall under Anthropic's Commercial Terms, to which the consumer training changes do not apply (https://www.anthropic.com/news/updates-to-our-consumer-terms) [P, via search snippet]. I did not read the current Commercial Terms text. | — |
| Templates / custom note formats | Not mentioned. UNVERIFIED (Inference: none at launch). | — |
| Hybrid manual + AI notes | Not a notepad. People can edit what Claude made on the meeting page. No "write your own notes, AI enhances" flow described. | [P] |
| API / MCP / webhook for meeting data | A reviewer found none. | https://cellcog.ai/blog/claude-meetings/ (2026-11-12, competitor) [S] |
| STT vendor / model | Not disclosed. | VentureBeat [S] |

Early reactions (the product is 1–3 days old; evidence is thin and I found **no Reddit or Hacker News thread**):
- Positive: a LinkedIn commenter said the live output is far more advanced than a meeting summary (reported by search summary of https://www.linkedin.com/posts/guillermoflor_breaking-anthropic-just-launched-claude-activity-7526784777287483394-q3NE) [S, UNVERIFIED wording].
- Sceptical: DEV post "Claude Joined My Meeting And Microsoft Lost 2.26 Percent" https://dev.to/dishant0406/claude-joined-my-meeting-and-microsoft-lost-226-percent-pfi [S].
- Open questions raised by commenters and reviewers: mixed-language calls (a LinkedIn commenter asked about Norwegian/English/German, no answer found); no retention period; Google Meet only; Team/Enterprise only; leaves when an outsider joins; no API/MCP; consent is left to the team. (vanja.io, lycore.com 2026-11-13, cellcog.ai) [S].

#### 1.2 "Parka" desktop recorder — RUMOURED, unreleased

- RuntimeWire, 2026-08-19 (paywalled after intro): https://runtimewire.com/article/anthropic-s-project-parka-sits-through-meetings-and-assigns-claude-agents-the-ho [S]. Visible text: Mac-first, captures system and microphone audio, streams speaker-attributed transcripts, creates runnable work for Claude's agents; based on interfaces in Claude Desktop build 1.32885.1; no Parka UI was present in the reviewed material.
- Reworked, 2026-08-25: https://www.reworked.co/digital-workplace/anthropic-explores-meeting-recorder-that-assigns-tasks-to-claude-agents/ [S]. Adds: macOS 13+, timestamped speaker-labelled transcript, notes and summary, action items with title/owner/instructions routed to Cowork, Code or a person; "Anthropic did not respond to a request for comment"; "The feature isn't public and Anthropic has yet to confirm it."
- Search summaries of other outlets say public builds mark the feature unavailable and the native loader is an empty stub (UNVERIFIED; I did not read those pages).
- **Not known:** on-device vs cloud transcription, storage, limits, languages, plans, date. Nothing newer than August 2026 was found.
- Inference: if shipped, Parka is the direct competitor to a local macOS recorder (same capture method, no bot). Nothing indicates it would process audio on-device.

#### 1.3 Other Claude routes to meeting notes

- **Connectors (MCP) from third-party notetakers** in Claude's directory: Fireflies, Granola (launched its MCP 2026-02-04), Otter, Fathom, Circleback, tl;dv, Fellow are reported as listed. Sources are vendor blogs (https://tactiq.io/learn/ai-meeting-notetaker-with-claude-connector, https://fellow.ai/blog/ai-meeting-notetaker-claude-connector/, https://www.read.ai/resources/best-ai-meeting-notetakers-for-claude-2026-connectors-compared) [S]; dates and verification tiers conflict between them. UNVERIFIED against claude.com/connectors.
- **Community tools, not Anthropic products:** https://github.com/dariuszparys/claude-meeting-notes (Claude Code mod, mic + system audio, local transcript) and https://github.com/emishin/meetingrecorder-claude [S].
- Release notes show no other meeting/recording/transcription entry (the only matches were Claude Meetings 2026-11-12, mobile calendar access 2025-09-03, and Claude in Chrome workflow recording 2025-12-18) [P].
- No acquisition or partnership for meeting capture was found beyond the "coming soon" transcript export partners above.
- Guides written before November 2026 saying "Claude cannot record meetings" are now outdated for Team/Enterprise + Google Meet, and still accurate for individuals, Zoom/Teams, in-person and offline use.

---

### PART 2 — Competitors

#### Granola
- Capture: device audio on desktop, no bot; iOS, Android, Apple Watch apps; voice typing. https://www.granola.ai/pricing [P, read 2026-11-13]
- Price [P]: Basic USD 0 (30-day visible history), Business USD 14/user/month, Enterprise USD 35/user/month. Recipes on all plans. MCP: Basic = personal notes, last 30 days; Business = personal + workspace notes. API only Business+. Model-training opt-out is per user on Basic/Business, workspace-wide only on Enterprise.
- Hybrid notes: user's own notes are merged with the transcript ("enhance") [S: https://thesweetbits.com/tools/granola-ai-review/]. Recipes = reusable prompt shortcuts invoked with "/" (launched autumn 2025) [S: https://finance.yahoo.com/news/ai-note-taking-app-granola-164556011.html].
- Languages [P]: https://docs.granola.ai/help-center/customising-granola/multi-language — 31 desktop languages, **Polish not among them**; 17 mobile languages, **Polish included**. Desktop can mix up to 10 hinted languages; mobile picks one language per meeting; no re-transcription later.
- Speaker ID: desktop labels "Me"/"Them"; some reviews report newer speaker tags and name mapping for Zoom/Meet [S, conflicting; UNVERIFIED].
- Audio: deleted after transcription, no playback [S: https://anarlog.so/blog/granola-ai-complaints/ citing Granola docs, 2026-10-11, competitor].
- 2026 events: MCP 2026-02-04; local cache broken ~2026-03-10 then encrypted (no plaintext by June 2026), CEO: "This is on us"; USD 125M Series C at USD 1.5B, 2026-03-25 (https://siliconangle.com/2026/03/25/granola-raises-125m-1-5b-valuation-ai-note-taking-app/); personal API; workaround blocked July 2026 (timeline: https://superframeworks.com/articles/granola-encrypted-local-notes, 2026-09-26) [S].
- Legal: *Chamberlain v. Granola*, N.D. Cal., No. 3:26-cv-07926, filed 2026-07-30, proposed class action alleging capture without all-party consent and default AI training; no merits ruling as of late October 2026 (https://www.layer3labs.io/guides/granola-lawsuit, https://ppc.land/granola-sued-for-recording-meetings-without-consent-to-train-ai-models/) [S].
- Other criticisms [S, competitor-authored]: silent capture failures, not HIPAA compliant, US hosting, English-only UI, CSV export once per 24 h.
- Strengths: calm notepad UX, hybrid notes, no bot, Recipes, MCP. Weaknesses: cloud, no audio, weak desktop speaker labels, no desktop Polish, lock-in complaints, consent lawsuit.

#### ChatGPT Record (OpenAI)
- macOS desktop app only; captures audio locally, transcribes in the cloud, writes notes to a canvas; Plus launch 2025-07-16 (https://x.com/OpenAI/status/1945547821626913059, https://9to5mac.com/2025/07/16/chatgpt-for-mac-rolls-out-record-mode-for-plus-subscribers/) [S].
- Help page https://help.openai.com/en/articles/11487532-chatgpt-record returned 403; details from search snippets: works best in English, other languages vary; audio deleted after transcription and not used for training; off by default on Enterprise/Edu. Session cap reported as 120 min (2025) and 240 min (2026 snapshots); speaker labels reported both ways. All UNVERIFIED.

#### Notion AI Meeting Notes
- Desktop app captures mic + system audio, no bot; browser = mic only. Business (USD 20/seat/month yearly) and Enterprise. 16 languages, Polish not listed; speaker labels English only [S: https://scribbl.co/post/notion-ai-meeting-notes, https://tldv.io/blog/notion-ai-meeting-notes-review/]. UNVERIFIED on Notion's help page.
- Reddit summary (competitor's manual labelling of 35 threads, 2026-10-26): 58 positive / 62 negative / 30 mixed; top complaint speaker labels (24), then price (20), transcription stopping mid-meeting (17), wrong-language output (16); top praise: notes live in Notion, summaries, no bot. https://metawhisp.com/blog/notion-ai-meeting-notes-review/ [S].

#### Fathom
- Bot by default; bot-free Mac capture in beta; free plan with unlimited recording, capped AI summaries (5/month reported); Premium about USD 20/month; 38 transcript languages reported; Polish reported on its list [S: https://get-alfred.ai/blog/fathom-pricing, https://www.noterai.net/best/polish-meeting-transcription-app]. UNVERIFIED on Fathom's pages. Claude connector reported [S].

#### Otter
- Bot ("OtterPilot"). Litigation: *In re Otter.AI Privacy Litigation* (lead case *Brewer v. Otter.ai*, N.D. Cal., 5:2025cv06911); order of 2026-08-13 granted the motion to dismiss in part, section 631 claims proceed; in discovery, no class certified (https://docs.justia.com/cases/federal/district-courts/california/candce/5:2025cv06911/454675/68, https://scribbl.co/post/otter-ai-lawsuit) [S].
- Polish: conflicting (one Polish outlet says Polish was added, another review says it is not supported). UNVERIFIED.

#### Fireflies
- Bot by default (a no-bot desktop mode is reported, with "Speaker 1/2" labels and no saved audio) [S]. Pro USD 10/seat annual (18 monthly), Business USD 19 (29), Enterprise USD 39; AI credits extra; free storage cut to 400 minutes for accounts from 2026-09-01 [S: https://privatenotetaker.com/blog/fireflies-pricing/]. 100+ languages incl. Polish with auto-detect [S]. First meeting connector in Claude's directory (Aug 2025) [S].

#### Krisp
- Bot-free system-level capture; Core USD 8/month annual, Advanced USD 15; about 16 languages **including Polish**; English may run on-device, other languages on Krisp servers [S: https://meetingcompare.com/pricing/krisp-pricing/, https://cldebloat.com/blog/krisp-ai-meeting-assistant-review/]. UNVERIFIED on Krisp's pages.

#### Apple
- Notes on Mac records and transcribes audio; Apple Intelligence can summarize a recording; "audio transcription isn't available in all languages"; listed languages do not include Polish (https://support.apple.com/guide/notes/record-and-transcribe-audio-apdb5106e334/mac, https://support.apple.com/guide/mac-help/mchl2102c2ae/mac) [P via search snippets].
- WWDC 2026 (https://www.macstories.net/news/wwdc-2026-small-details-and-compatibility-lists/, ~2026-06-08) [S]: Call Recording transcription added Traditional Chinese, Japanese, Brazilian Portuguese; Notes got Markdown copy/paste and small features. **No meeting-notes product, no system-audio meeting capture and no Polish were found** for macOS 27 / iOS 27.

#### Zoom AI Companion
- 3.0 launched 2025-12-15; notes for in-person and third-party meetings (Teams, Meet); included with paid Zoom Workplace; USD 10/month standalone; Custom AI Companion add-on (https://www.reworked.co/collaboration-productivity/zoom-launches-ai-companion-30-with-10-standalone-option/) [S]. Polish UNVERIFIED.

#### Google Meet (Gemini "Take notes for me")
- Eight languages (English, French, German, Italian, Japanese, Korean, Portuguese, Spanish); **no Polish**; one language per meeting (https://support.google.com/meet/answer/14925782) [P via search snippet]. Opened to AI Pro/Ultra subscribers in June 2026 (https://www.androidauthority.com/google-meet-take-note-for-me-expansion-3682506/) [S].

#### Microsoft Teams (Copilot, Facilitator, intelligent recap)
- Facilitator needs a Copilot licence; recap needs Teams Premium or Copilot; about 40 languages, one per meeting [S: https://www.aguidetocloud.com/blog/microsoft-365-facilitator-agent/]. Polish UNVERIFIED. Teams added controls that hold external notetaker bots in the lobby during 2026 (timing conflicts) [S: https://www.meetingcopilot.app/blog/ai-notetaker-blocked-teams-google-meet-2026].

#### Limitless (Meta)
- Acquired by Meta December 2025; Pendant sales stopped 2025-12-05; existing customers supported through 2026; Rewind features reportedly discontinued and service ended in the EU/UK (UNVERIFIED) [S: https://mlq.ai/news/meta-acquires-ai-wearables-startup-limitless-ending-sales-of-pendant-device/].

#### Plaud
- NotePin S and Plaud Desktop (beta, macOS/Windows, bot-free capture of Zoom/Meet/Teams) announced 2026-01-04 (https://www.plaud.ai/blogs/news/plaud-unveils-notepins-and-desktop) [P via search]. Cloud processing. Language count and Polish UNVERIFIED. Named as a future Claude Meetings export partner [P].

#### tl;dv, Jamie, Circleback
- tl;dv: bot; Pro USD 18 annual, Business USD 29; Polish reported on its list [S].
- Jamie: bot-free, Germany/EU-hosted, audio deleted after transcription; prices conflict (EUR 39–47/month) [S]. Polish UNVERIFIED.
- Circleback: Pro USD 15 annual, Business USD 25; free plan since August 2026 per its own blog; Claude connector (https://circleback.ai/blog/ai-meeting-notetaker-pricing-compared) [vendor].

#### Local / private macOS tools
- **Anarlog (formerly Hyprnote, briefly Char)**: open source, local-first, system audio, SQLite, Ollama/LM Studio (https://github.com/fastrepl/anarlog) [P via search]. Naming is inconsistent across pages; per the repo, "char" is now the team's other productivity app.
- **Meetily**: MIT, on-device Whisper/Parakeet + diarization, summaries through Ollama or own API key; macOS/Windows (https://github.com/Zackriya-Solutions/meetily) [P via search]. Pro pricing conflicts.
- **MacWhisper**: one-time about EUR 64 Pro; meeting recording with live transcript, up to eight speakers since 15.2 [S].
- **Talat**: local, no account, one-time purchase, macOS 15+ Apple silicon and Windows (https://talat.app/) [P via search].
- **Alter**: local transcription, Ollama [S]. **Shadow**: bot-free, transcription on the Mac, external providers for AI (https://www.shadow.do/...) [vendor]. **Slipbox**, **Quill Meetings**, **Muesli**, **OpenWhispr**, **pasrom/meeting-transcriber**: local options named in roundups [S].
- Inference: the local field is crowded with Whisper/Parakeet wrappers; none was found with documented Polish quality, a hybrid notepad on Granola's level and encrypted storage together.

#### Polish support summary
| Product | Polish | Source quality |
|---|---|---|
| Claude Meetings | not stated | primary pages silent |
| Granola | mobile only, not desktop | primary |
| Google Meet Gemini notes | no | primary snippet |
| Notion AI Meeting Notes | not listed | secondary |
| Apple Notes transcription | not listed | primary snippet |
| ChatGPT Record | "best in English" | snippet, UNVERIFIED |
| Krisp, Fireflies, Fathom, tl;dv | listed | secondary |
| Otter | conflicting | secondary |

No independent Polish accuracy benchmark for any product was found. The one "rated for Polish" article is a vendor page with no WER (https://www.noterai.net/best/polish-meeting-transcription-app, 2026-10-11).

#### Comparison table
| Product | Capture | Bot? | Processing | Speaker ID | Polish | Hybrid notes | Templates | Ask archive | MCP / integrations | Price |
|---|---|---|---|---|---|---|---|---|---|---|
| Claude Meetings (beta) | Joins Google Meet | Yes, visible | Cloud; no audio kept | not described | not stated | No (editable page) | not mentioned | Yes | Connectors in-call; export partners "coming soon"; no API found | In Team/Enterprise during beta |
| Claude "Parka" (rumour) | Mac system + mic | No | unknown | reported | unknown | unknown | unknown | unknown | Cowork/Code tasks | unknown |
| Granola | Device audio | No | Cloud; audio deleted | Me/Them (+tags, unverified) | mobile only | Yes | Recipes | Yes | MCP, API (paid) | 0 / 14 / 35 USD |
| ChatGPT Record | Mac app | No | Cloud | conflicting | English best | No | No | via chat memory (unverified) | — | in paid plans |
| Notion | Desktop mic + system | No | Cloud | English only | no | Yes (in page) | Notion templates | Yes | Notion | Business 20 USD |
| Fathom | Bot (bot-free beta) | Usually | Cloud | Yes | listed | No | Yes | Yes | connector | free / ~20 USD |
| Otter | Bot | Yes | Cloud | Yes | conflicting | No | Yes | Yes | connector | UNVERIFIED |
| Fireflies | Bot (no-bot mode) | Usually | Cloud | Yes | listed | No | Yes | Yes | MCP | 10–39 USD |
| Krisp | System level | No | Cloud (English on-device) | Yes | listed | No | Yes | Yes | — | 8–15 USD |
| Google Meet Gemini | Native | No | Cloud | Yes | no | No | No | Gemini | Workspace | in plans |
| Teams Copilot | Native | No | Cloud | Yes | unverified | Facilitator | No | Copilot | M365 | Copilot licence |
| Zoom AI Companion | Native + other | No | Cloud | Yes | unverified | No | Yes | Yes | Zoom | in paid Zoom |
| Apple Notes | Mic recording | No | On-device | No | no | manual | No | No | — | free |
| Plaud Desktop | System audio | No | Cloud | Yes | unverified | No | Yes | Ask Plaud | — | plan-based |
| Jamie | System audio | No | Cloud (EU) | Yes | unverified | No | Yes | Yes | — | ~39–47 EUR |
| Meetily / Anarlog / Talat / MacWhisper | System audio | No | On-device | varies | model-dependent | Anarlog yes | varies | limited | Ollama | free / one-time |

Cells without a source in the sections above are my summary of secondary reviews and should be treated as UNVERIFIED.

---

### PART 3 — What users say

Caveat: Reddit could not be read directly; Hacker News searches returned no relevant thread. The patterns below come from reviews, vendor-collected user reports, legal coverage and institutional notices.

Recurring complaints
1. **Wrong or missing speaker attribution** — the top Notion complaint (24 mentions in the MetaWhisp sample); Granola desktop merges all remote speakers into "Them", so action items lose their owner.
2. **Notes that cannot be trusted or checked** — tentative ideas turned into firm action items with a name and date (https://lovex.dev/blog/ai-notetakers-action-items); no audio to verify against in Granola and Claude Meetings.
3. **Silent capture failure** — a session looks live and records nothing (Granola user reports via anarlog.so); transcription stopping mid-meeting (Notion).
4. **Bots are intrusive** — universities blocked or warned against Read.ai/Fireflies (Cornell, University of Washington advisory 2026-07-07, Maryland, Harvard guidance), Teams now quarantines external bots (https://basilai.app/articles/2026-05-09-organizations-banning-cloud-ai-notetakers-harvard-heppner-privilege-waiver.html, vendor blog; UNVERIFIED against the universities' pages).
5. **Consent and legal exposure** — Otter and Granola class actions; "no bot" does not remove the consent problem (Granola's suit is about invisible capture).
6. **Privacy / training / employer rules** — training on by default with per-user opt-out (Granola Basic/Business), US hosting, no HIPAA; companies allow only security-approved notetakers.
7. **Language** — wrong-language output, one language per meeting, small language lists (Google 8, Notion 16); Polish gaps listed above.
8. **Cost and gating** — features behind Business tiers, AI credits (Fireflies), shrinking free tiers.
9. **Lock-in** — Granola's encrypted cache and paid API; CSV export once a day.

Recurring praise: no bot in the call; the hybrid notepad (own notes + AI); everything in one workspace (Notion); good summaries and action items when speakers are clear; MCP access to past meetings from Claude/ChatGPT.

Why people move to Granola: no bot, clean notes, hybrid flow. Why they leave: privacy and consent, no audio, speaker labels, language, lock-in, free-plan history limit (sources: competitor blogs; treat as leads).

What "better than Claude / Granola" would mean (Inference, tied to the gaps above)
- Works for one person on any plan, in any app (Zoom, Teams, Meet, in person, offline) — Claude Meetings is Team/Enterprise + Google Meet only.
- No participant bot, and nothing leaves the Mac — Claude Meetings is a cloud bot and excludes ZDR/HIPAA/CMEK customers.
- Polish and mixed Polish/English that is stated and measured — Claude says nothing; Granola desktop has no Polish.
- Real speaker separation with easy renaming, and the option to keep audio so a note can be checked against what was said.
- A visible recording state and a failure alert, so a call is never silently lost.
- Action items that quote their source sentence, to counter invented tasks.
- Open, user-owned data (plain export, local MCP) — the opposite of Granola's encrypted cache.
- A built-in consent aid (reminder or announcement text), since "no bot" does not remove the legal duty.
- Where Claude is stronger and a local tool will not match soon: live artifacts during the call, answering questions in the call with connector data, team sharing and recap emails.


---

# CZĘŚĆ B: techniki

## On-device meeting notes on Apple silicon: techniques, late 2026

Research date: 2026-11-13. Scope: Polish + English (with code-switching), Macs with 16-64 GB RAM, Swift app using FluidAudio (Parakeet TDT, diarization), WhisperKit and llama.cpp (Qwen3-4B).

### How to read this file

- **FACT** lines carry a source URL and the source's date. "Fetched" means I opened the page on 2026-11-13. "Snippet" means the number came from a search-result summary and I did not open the page.
- **UNVERIFIED** means I could not confirm it from a primary source today. This includes things I know from background knowledge but did not re-fetch.
- **RECOMMENDATION** blocks are my opinion, kept apart from the facts.
- Benchmarks from different papers use different protocols (collar, overlap scoring, text normalisation, reference labels). Numbers are comparable only inside one table of one source.

---

### 1. ASR for Polish + English

#### 1.1 What exists and whether it supports Polish

| Model | Size | Licence | Polish? | Source (date) |
|---|---|---|---|---|
| NVIDIA Parakeet TDT 0.6b v3 | 600M | CC-BY-4.0 (UNVERIFIED today, from background knowledge) | Yes, 25 European languages | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 (snippet) |
| NVIDIA Nemotron Unified ASR 0.6B (`nemotron-labs-unified-asr-0.6b`) | 600M | OpenMDW 1.1, commercial use allowed | Yes, 25 European languages; offline and streaming | https://huggingface.co/nvidia/nemotron-labs-unified-asr-0.6b (fetched; released 2026-10-27) |
| NVIDIA Nemotron 3.5 Transcribe 30B-A4B | 34B total, about 4.3B active | OpenMDW 1.1 | Yes, "production-ready"; code-switching listed as supported for Polish; multispeaker ASR not listed for Polish | https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B (fetched; released 2026-10-28) |
| NVIDIA Canary 1B v2 | 1B | CC-BY-4.0 (UNVERIFIED today) | Yes | https://arxiv.org/abs/2509.14128 (Sept 2025) |
| NVIDIA Canary-Qwen 2.5B | 2.5B | CC-BY-4.0 | **No**, English only | https://huggingface.co/nvidia/canary-qwen-2.5b (snippet) |
| OpenAI Whisper large-v3 / large-v3-turbo | 1.55B / 809M | MIT (UNVERIFIED today) | Yes | see 1.2 |
| Cohere Transcribe 03-2026 | 2B | Apache 2.0 (secondary sources; HF download asks for contact details) | Yes, one of 14 languages; no automatic language detection | https://docs.cohere.com/v1/changelog/cohere-transcribe-03-2026 (snippet, March 2026) |
| Qwen3-ASR 0.6B / 1.7B | 0.6B / 1.7B | Apache 2.0 | Appears in benchmark tables, weak | https://arxiv.org/html/2601.21337v1 (snippet, Jan 2026) |
| Mistral Voxtral Realtime (`Voxtral-Mini-4B-Realtime-2602`) | 4B | Apache 2.0 | **No** (13 languages: EN ZH HI ES AR FR PT RU DE JA KO IT NL) | https://mistral.ai/news/voxtral-transcribe-2/ (snippet, Feb 2026) |
| Mistral Voxtral Mini Transcribe V2 (batch, with diarization) | n/a | API only, not open | n/a | same |
| Mistral Voxtral Small 24B (2507) | 24B | Apache 2.0 (UNVERIFIED today) | Evaluated on Polish in PUMA | see 1.2 |
| IBM Granite Speech 4.1 2B | 2B | Apache 2.0 | **No** (EN FR DE ES PT, plus JA on the standard model) | https://huggingface.co/ibm-granite/granite-speech-4.1-2b-plus (snippet) |
| Kyutai STT (`stt-1b-en_fr`, `stt-2.6b-en`) | 1B / 2.6B | CC-BY-4.0 | **No** (English, French) | https://huggingface.co/kyutai/stt-1b-en_fr (snippet) |
| Moonshine ("Flavors", v2 streaming) | tiny | UNVERIFIED | No Polish model found (AR ZH JA KO UK VI added) | https://arxiv.org/abs/2509.02523 (snippet, Sept 2025); v2 language list UNVERIFIED |
| Apple SpeechAnalyzer / SpeechTranscriber | system | system | **No** | see 1.4 |

#### 1.2 Polish accuracy numbers

**Clean read speech (FLEURS / MLS).** All are close to each other and flatter than real meetings.

- FACT: Parakeet TDT v3, Polish FLEURS WER 7.31% (model-card index); MLS Polish 7.28% vs Canary-1B-v2 8.77% and Whisper large-v3 8.88% in the NVIDIA paper. https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 and https://arxiv.org/pdf/2509.14128 (snippets; the PDF did not parse when I fetched it).
- FACT: Parakeet TDT v3 in FluidAudio's CoreML build, Polish FLEURS WER 8.6%, CER 2.8%, 190x real time on an M4 Pro. https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md (fetched).
- FACT: Nemotron Unified ASR 0.6B, Polish WER averaged over FLEURS, Common Voice and MLS: 6.01% offline, 7.09% at 1.12 s latency, 7.84% at 0.56 s. Across all 25 languages it scores 9.49% vs 10.55% for Parakeet v3. The card does not mention timestamps or code-switching. https://huggingface.co/nvidia/nemotron-labs-unified-asr-0.6b (fetched).
- FACT: Nemotron 3.5 Transcribe, Polish FLEURS WER 3.81%. Recommended hardware is an H100 80 GB; recordings up to one hour. https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B (fetched).
- FACT: Whisper large-v3-turbo, Polish FLEURS WER 5.45% (about 150 sentences, M5 MacBook Air, macOS 27.0); Apple Dictation 13.50%; Apple Speech returned nothing for Polish. https://whispernotes.app/blog/apple-speech-vs-whisper (fetched; published 2026-09-01, updated 2026-10-31; a vendor blog).
- FACT: Qwen3-ASR Polish WER: FLEURS 12.54% (1.7B) and 24.71% (0.6B); MLS 15.26% and 26.09%. https://arxiv.org/html/2601.21337v1 (snippet).

**Harder real-world Polish (PUMA benchmark, Aug 2026).** 100 recordings of one to several minutes, often noisy, with complex language or dialect. "Soft" is word accuracy, max(0, 1 - WER); "strict" is the count of recordings with word accuracy of at least 0.9. https://arxiv.org/html/2608.21853 (fetched; submitted 2026-08-22; authors Dadas et al.)

| Model | Strict (of 100) | Soft (word accuracy) |
|---|---|---|
| ElevenLabs Scribe V2 (cloud) | 81 | 93.23 |
| GPT-4o-Transcribe (cloud) | 66 | 86.45 |
| **Whisper large-v3** | 63 | 86.40 |
| **Whisper large-v3-turbo** | 56 | 85.69 |
| Whisper medium | 51 | 82.68 |
| Cohere Transcribe 03-2026 | 46 | 81.51 |
| Microsoft VibeVoice-ASR | 41 | 80.27 |
| Canary 1B v2 | 38 | 78.88 |
| **Parakeet TDT 0.6B v3** | 36 | 79.80 |
| Voxtral Small 24B 2507 | 36 | 80.27 |
| Qwen3-ASR 1.7B | 24 | 74.79 |
| Qwen3-ASR 0.6B | 4 | 65.97 |

- FACT: the authors conclude that Whisper "performs surprisingly well in Polish", that newer open models trail Whisper large-v3 on Polish, and that Open ASR Leaderboard rank does not predict Polish quality. Same source.
- Caveat: the fetch tool's summary was internally inconsistent about whether Voxtral Small sits in the ASR table or only in the audio-instruct group. Treat the Voxtral row as UNVERIFIED. Nemotron Unified and Nemotron 3.5 came out after the paper and are not in it.

**Leaderboards.**

- FACT: the Open ASR Leaderboard multilingual track covers DE, FR, IT, ES, PT (plus HI and NL in later snapshots). Polish is not in it. Voxtral Small 24B averages 3.70, Canary 1B v2 4.60, Qwen3-ASR 1.7B 5.11 on the five-language version. https://arxiv.org/html/2510.06961v4 (snippet).
- FACT: BIGOS V2 / Polish ASR Leaderboard (NeurIPS 2024 Datasets track): best systems were Whisper large-v3, Whisper cloud and AssemblyAI; on conversational PELCRA data the median WER was 29.90% for paid and 34.18% for free systems, against 12.96% and 15.47% on read speech. https://papers.nips.cc/paper_files/paper/2024/file/69bddcea866e8210cf483769841282dd-Paper-Datasets_and_Benchmarks_Track.pdf (snippet). **Possibly outdated**: 2024 results, no 2026 refresh found.

#### 1.3 Code-switching and hallucination

- FACT: no Polish-English code-switching ASR benchmark turned up in my searches. The published work is on Mandarin-English and German-English.
- FACT: an INTERSPEECH 2026 paper adds code-switching to strong multilingual ASR by "Bayesian factorized adaptation" with a small amount of synthetic data: 32.87% fewer errors on code-switched words and 5.31% better overall WER, with monolingual accuracy kept. Models and languages are not named in the abstract. https://arxiv.org/abs/2606.21990 (fetched; 2026-06-20).
- FACT: a metric for this problem is PIER (point-of-interest error rate), which scores only the embedded-language words. https://arxiv.org/pdf/2606.21990 (snippet).
- FACT: Nemotron 3.5 Transcribe lists code-switching as supported for Polish. No numbers given. Same card as above.
- FACT: Parakeet-family models take a language hint; FluidAudio's notes say "v3 language hints are script-level". https://github.com/FluidInference/FluidAudio/releases (fetched; v0.18.2, 2026-11-01).
- FACT: Whisper hallucination on non-speech. Calm-Whisper reports over 80% fewer non-speech hallucinations after fine-tuning three decoder heads (https://arxiv.org/pdf/2505.12969, snippet, May 2025). A 2026 steering paper reports the hallucination rate on a non-speech test set falling from 86.88% to 27.33% for large-v3 (https://arxiv.org/pdf/2606.07473, snippet). VAD gating before decoding is the standard mitigation; Whisper's own `no_speech_threshold` is not a hard gate (https://arxiv.org/pdf/2501.11378, snippet, Jan 2025).
- UNVERIFIED: transducer and CTC models (Parakeet) hallucinate less on silence than Whisper. Widely stated; I did not find a Polish-specific measurement.

#### 1.4 Apple SpeechAnalyzer / SpeechTranscriber

- FACT: Polish is not supported. As of August 2026 `SpeechTranscriber.supportedLocales` returned 42 locales in 22 languages, without Polish (https://loronote.com/en/blog/apple-speechanalyzer-vs-whisper, snippet). The whispernotes test on macOS 27.0 also got no Polish result (fetched, see above).
- FACT: on English long-form speech Argmax measured SpeechTranscriber at 14.0 WER on earnings22, between whisper-base.en (15.2) and whisper-small.en (12.8). https://www.argmaxinc.com/blog/apple-and-argmax (snippet, 2025). **Possibly outdated.**
- FACT: on FLEURS, Whisper large-v3-turbo beat Apple Speech in English (5.49 vs 8.80) and German (4.05 vs 6.26). whispernotes source above.

#### 1.5 Availability and speed on Apple silicon

- FACT: FluidAudio 0.18.x ships, among others: Parakeet v3 and its variants **Parakeet Ultra** (post-trained v3, int8 encoder 595 MB, FLEURS 24-language mean WER 11.67% vs 14.81% for v3) and **Parakeet Redux** (2-bit encoder, about 220 MB download, 13.06%); **Nemotron Unified ASR 0.6B** (`--model-version nemotron-unified`, CoreML repo `FluidInference/nemotron-labs-unified-asr-0.6b-coreml`); **Nemotron 3.5 Transcribe Lite** (encoder plus CTC timestamp head, no LLM; words with 40 ms start times; runs Nemotron-3-Diarization in parallel on the Neural Engine; a 49.5-minute meeting in about 5.5 s on an M5 Pro); Canary speech translation; a Cohere encoder/decoder; LFM3-Audio-2B; SenseVoice; LocalVQE echo cancellation (beta). https://github.com/FluidInference/FluidAudio/releases (fetched; v0.17.3 2026-09-24 through v0.18.3 2026-11-07).
- FACT: an older FluidAudio release removed an experimental Qwen3-ASR backend. Search snippet only; version UNVERIFIED.
- FACT: per-language Polish numbers for Ultra, Redux, Nemotron Unified in CoreML and Transcribe Lite are **not published** in the FluidAudio pages I read.
- FACT: speed on an M5 MacBook Air, short FLEURS clips (isolated-item throughput, not product latency): Parakeet v3 75.6x real time with 0.09 GiB peak memory; Whisper large-v3-turbo 3.0x with 1.87 GiB; Qwen3-ASR 1.7B 11.1x with 2.43 GiB; Apple Speech 30.8x. whispernotes source above (the engine behind the Whisper figure is not stated in my extract).
- FACT: Argmax reports WhisperKit large-v3-turbo at 42x real time by default (Neural Engine) and up to 72x (GPU + ANE) on an M2 Ultra. https://github.com/argmaxinc/argmax-oss-swift/discussions/243 (snippet, Nov 2024). **Possibly outdated**, and it conflicts with the 3.0x above; the two tests differ in hardware, clip length and probably engine.
- FACT: GGUF builds of Nemotron 3.5 Transcribe exist from third parties (https://huggingface.co/AtomicChat/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-GGUF, snippet). Whether they run usefully on a 32-64 GB Mac is UNVERIFIED.

#### RECOMMENDATION (ASR)

1. For Polish meetings, treat **Whisper large-v3 (or turbo) as the accuracy reference** and Parakeet v3 as the fast path. PUMA shows a gap of about 6-7 word-accuracy points on hard Polish audio that FLEURS hides.
2. Benchmark **Nemotron Unified ASR 0.6B** and **Parakeet Ultra** on your own Polish meeting first. Both are already in the FluidAudio version you pin (0.18.2), both claim gains over v3, and neither has a published real-world Polish number.
3. Test **Nemotron 3.5 Transcribe Lite** for word timestamps plus speakers in one pass; it attacks the speaker-mixing problem directly (section 2).
4. Skip for Polish: Voxtral Realtime, Granite Speech, Kyutai, Moonshine, Canary-Qwen, Apple SpeechTranscriber (no Polish) and Qwen3-ASR (weak Polish).
5. Build a small code-switching test set and score English jargon words separately (PIER-style). No public Polish-English benchmark exists, so nobody else's number will tell you this.
6. Keep VAD gating in front of Whisper on both channels; the system-audio channel has long silences.

---

### 2. Diarization

#### 2.1 Models and published DER

| System | Licence | AMI | VoxConverse | Protocol | Source (date) |
|---|---|---|---|---|---|
| pyannote legacy 3.1 | MIT (UNVERIFIED today) | IHM 18.8 / SDM 22.7 | 11.2 | no collar, overlap scored | https://huggingface.co/pyannote/speaker-diarization-community-1 (snippet; table updated 2025-09) |
| pyannote community-1 | CC-BY-4.0 (UNVERIFIED today) | IHM 17.0 / SDM 19.9 | 11.2 | same | same |
| pyannoteAI precision-2 | commercial, hosted | IHM 12.9 / SDM 15.6 | 8.5 | same | same |
| DiariZen (`diarizen-wavlm-large-s80-md`) | code MIT, **weights CC BY-NC 4.0** | 14.0 | 9.2 | collar 0 | https://huggingface.co/BUT-FIT/diarizen-wavlm-large-s80-md (fetched) |
| NVIDIA Nemotron 3 Diarization (100M, up to 8 speakers, streaming and offline) | OpenMDW 1.1 | MHM 9.25 / SDM 11.14 at 30.4 s latency; SDM 12.95 at 0.32 s | not evaluated | collar 0, overlap included, **forced-alignment reference labels** (not comparable to the rows above) | https://huggingface.co/nvidia/Nemotron-3-Diarization (fetched; released 2026-09-23) |
| NVIDIA streaming Sortformer 4spk v2.1 (baseline on that card) | UNVERIFIED | MHM 15.81 / SDM 21.42 | - | same as Nemotron row | same |

- FACT: Nemotron 3 also reports DIHARD III 12.73, CALLHOME part 2 9.10 (0.25 s collar), NOTSOFAR-1 single-channel 11.00 vs 30.49 for the Sortformer baseline. Same card. Paper: https://arxiv.org/abs/2611.12246 (snippet, Nov 2026).
- FACT: an independent benchmark (ETH Zurich, 196.6 h, 0.25 s collar) puts PyannoteAI at 11.2% DER and DiariZen at 13.3% as the best open option, and finds that errors come mainly from missed speech, then speaker confusion, worst with many speakers. https://arxiv.org/html/2509.26177v1 (snippet, Sept 2025).
- FACT: a third-party TensorRT port measured Nemotron 3 at about 24-26% DER on AMI under its own setup, and says its figures compare implementations, not the published results. https://github.com/Wataru-Nakata/nemotron-diar-trt (snippet).

#### 2.2 What FluidAudio ships (v0.18.x)

- FACT: `OfflineDiarizerManager` = pyannote community-1 segmentation (10 s windows, 589 frames, 7 powerset classes) + WeSpeaker 256-d embeddings + AHC warm start + PLDA scoring + VBx refinement. VBx has no transition prior, so turn-taking comes only from the segmentation model; the knobs are `segmentation.stepRatio` and `minSegmentDurationSeconds`. https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md (fetched).
- FACT: since v0.18.2 the offline diarizer keeps overlapping speech by default (`exclusiveSegments: false`). On AMI SDM under the pyannote protocol: 20.3% DER overlapping, 24.2% exclusive; with step ratio 0.1 and no minimum segment, 18.3% and 23.1%; published community-1 is 17.0%. About 323x real time on an M5 Pro. https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md (fetched; measurements dated 2026-10-30).
- FACT: `exclusiveSegments: true` "trims a segment that starts while another is active, which is useful for attributing ASR words". GettingStarted.md above.
- FACT: v0.18.0 added per-chunk and per-speaker embeddings, `OfflineDiarizerManager.embedSpans` (one 256-d embedding per time span you supply) and "clean per-speaker embeddings for enrollment". v0.18.2 fixed CAM++ embeddings (`_v2`): AMI equal error rate 4.67% to 2.85% within a meeting, 3.55% across meetings. Releases page and Benchmarks.md above.
- FACT: v0.17.0 (2026-09-23) added `Nemotron3Diarizer` (8 speakers). v0.17.2 and v0.17.4 fixed crashes and Neural Engine compile failures on M3 and M5. FluidAudio's own DER for it is not on the pages I read. Releases page above.
- FACT: FluidAudio's older Sortformer port scored 31.7% DER on AMI SDM in streaming mode (M2), LS-EEND 20.7%. Benchmarks.md above.

#### 2.3 Fixing speaker-mixed segments

- FACT: the common fix is to assign a speaker **per word** from word timestamps, then split a segment wherever the word-level speaker changes, with a minimum run length so that one stray word does not create a segment. One open-source project reports "about a quarter fewer misattributed words, with no model change". https://github.com/kenhayward/Diariz/issues/803 (snippet). Single project, not a paper.
- FACT: WhisperX on its own labels whole segments; per-word assignment needs `assign_word_speakers`, and weak word timestamps from a mismatched alignment model are a common cause of merged turns. https://github.com/murtaza-nasir/whisperx-asr-service (snippet).
- FACT: punctuation-based realignment helps, but "when both speakers share a sentence roughly equally" it cannot fix the error. https://ufarooqi.com/essays/speaker-diarization (snippet).
- FACT: LLM post-correction of speaker tags (DiarizationLM and successors) reduces WDER (the share of words with the wrong speaker) on Fisher and TAL. https://arxiv.org/html/2409.00151v1 (snippet, 2024). The original DiarizationLM paper (arXiv 2401.03506) is UNVERIFIED today.
- FACT: Qwen3-ForcedAligner was open-sourced with Qwen3-ASR. https://qwen.ai/blog?id=qwen3asr (snippet). Polish support UNVERIFIED.
- FACT: end-to-end speaker-attributed ASR now exists in open weights (Nemotron 3.5 Transcribe: mean cpWER 15.80% over AMI, CALLHOME, Mixer 6, NOTSOFAR-1), but multispeaker ASR is not listed for Polish. Card above.

#### 2.4 Two channels, voiceprints, names

- FACT: capturing microphone and system audio as separate streams gives "the cheapest speaker separation you will ever get"; Granola labels the channels "Me" and "Them" and, on desktop, uses platform display names for Google Meet, Zoom and Teams. https://www.reline.so/blog/how-to-build-a-meeting-notetaker-without-a-bot and https://comparenotetakers.com/ai-notetakers-speaker-identification (snippets; vendor and comparison blogs, method not described).
- FACT: other bot-free Mac apps take names from the calendar invite through EventKit (Mac Note Taker, Circleback); one (Noted) claims to follow the live participant list without saying how. Notion's bot-free mode shows "Speaker 1 / Speaker 2". Same snippets.
- UNVERIFIED: reading the active speaker from the Zoom or Teams window through the Accessibility API. I found no source that documents it.
- FACT: Core Audio taps can be scoped to one process or a group of processes with `CATapDescription` (section 7), so a per-app tap is possible. Per-participant audio is not available: the meeting app mixes remote speakers before output (stated in the comparison source above).
- FACT (law): voiceprint lawsuits under Illinois BIPA are pending against Otter (consolidated *In re Otter.AI Privacy Litigation*), Fireflies and Microsoft Teams; the theory is that speaker identification across meetings stores a biometric voiceprint without written consent. All are at the pleading stage, and dates differ between sources. https://www.fisherphillips.com/en/insights/insights/ai-meeting-tools-are-the-latest-target-of-illinois-bipa-class-actions and https://scribbl.co/post/otter-ai-lawsuit (snippets; law-firm and vendor blogs, check the dockets).
- UNVERIFIED today (background knowledge): GDPR Art. 4(14) and Art. 9(1) make voice data a special category when it is processed to uniquely identify a person. https://eur-lex.europa.eu/eli/reg/2016/679/oj (not re-fetched).

#### RECOMMENDATION (diarization)

1. Your 15-20% speaker-mixed segments are mostly an **attribution-granularity problem**. Do word-level speaker assignment against **exclusive** diarization output, then re-segment at speaker changes with a minimum run (for example 2-3 words or 0.5 s) and snap to punctuation only when the boundary is within a word or two.
2. Keep the "me vs them" split from the two channels as a hard label and run diarization only on the system channel. This removes one speaker from the clustering problem.
3. Try `stepRatio 0.1` (2 points better on AMI at half the speed) and **Nemotron 3 Diarization** on your real meetings. Its published numbers are far better than community-1, but the reference labels differ and the Mac port is new.
4. DiariZen is ruled out by its non-commercial weights. Precision-2 is cloud only.
5. Cross-meeting voiceprints: keep them opt-in, local, per enrolled person, deletable, and never automatic for other participants. Prefer names from calendar attendees and from the transcript ("Thanks, Anna") as suggestions that the user confirms.

---

### 3. Local LLMs for notes

#### 3.1 Candidates that fit 16-32 GB

| Model | Size | Licence | Context | Notes | Source (date) |
|---|---|---|---|---|---|
| Gemma 4 E4B / 12B / 26B A4B / 31B | Q4_0 memory about 4.5 / 6.7 / 14.4 / 17.5 GB | Apache 2.0 | up to 256K (128K on the small ones per one version of the card) | "over 140 languages"; released about 2026-04-01 | https://ai.google.dev/gemma/docs/core/model_card_4 (snippet); https://venturebeat.com/technology/google-releases-gemma-4-under-apache-2-0-and-that-license-change-may-matter (snippet) |
| Qwen3.5 0.8B-9B | 9B | Apache 2.0 (secondary) | 262,144 native | thinking mode on by default; "201 languages" claim seen only on a mirror | https://huggingface.co/Qwen/Qwen3.5-4B/tree/main and mirrors (snippets) |
| Qwen3.6 35B-A3B | - | UNVERIFIED | UNVERIFIED | named in a Microsoft Foundry post title; specs not confirmed | https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/now-in-foundry-ibm-granite-4-1-nvidia-nemotron-nano-omni-and-qwen3-6-35b-a3b/4516858 (title only) |
| Bielik 11B v3.0 Instruct | 11B | Apache 2.0, **gated** (share HF details) | not stated on the card | 32 European languages, tuned for Polish; ChatML; 22 quantised derivatives; official GGUF repo exists | https://huggingface.co/speakleash/Bielik-11B-v3.0-Instruct (fetched; report dated 2025-12-30) |
| Bielik 4.5B v3.0 Instruct | 4.8B | Apache 2.0 per bielik.ai catalogue | 32,768 | adapted from Qwen2.5, own Polish tokenizer | https://arxiv.org/html/2505.02550v2 (fetched; May 2025) |
| Phi-4 | 14.7B | MIT (UNVERIFIED today) | UNVERIFIED | see Polish scores below | same Bielik report |
| Mistral Small 3.x (24B) | 24B | Apache 2.0 (UNVERIFIED today) | 128K for 3.2 | 3.2 is retired on Mistral's API | https://x.com/ArtificialAnlys/status/2034960206736892365 (snippet) |
| Mistral Small 4 | **119B MoE**, 6.5B active | Apache 2.0 | 256K | about 119 GB at FP8: does not fit the target Macs | https://huggingface.co/mistralai/Mistral-Small-4-119B-2603 (snippet, March 2026) |
| gpt-oss-20b | 21B | Apache 2.0 (UNVERIFIED today) | UNVERIFIED | 64 tok/s on M4 Pro 24 GB with MLX is an *estimate* | https://llmcheck.net/benchmarks (snippet) |
| Llama 4, Granite 4.x, PLLuM | - | - | - | **UNVERIFIED**: not checked today | - |

#### 3.2 Polish quality evidence

- FACT: Open PL LLM Leaderboard (5-shot average), instruction models: Bielik-11B-v2.3 65.71, Bielik-11B-v2.5 63.95, Mistral-Small-24B-2501 62.97, phi-4 62.57, Qwen2.5-14B 59.91, **Bielik-4.5B-v3.0 56.13**, Qwen2.5-7B 54.93, Phi-4-mini 43.30, Qwen2.5-3B 41.23. https://arxiv.org/html/2505.02550v2 (fetched). **Possibly outdated** (May 2025; no Qwen3, Gemma 3/4).
- FACT (snippet only, UNVERIFIED against the live leaderboard): Bielik-11B-v3.0 65.93, Qwen3-32B 64.24, Qwen3-14B 62.24, gemma-3-12b-it 62.2, Qwen3-8B 55.78, **Qwen3-4B 55.49**. Search result citing https://www.codesota.com/polish-llm; another page on that site shows numbers on a different scale, so do not rely on it.
- FACT: CPTUB (complex Polish text understanding): Bielik-11B-v2.3 3.63, Qwen2.5-14B 3.55, Bielik-4.5B-v3.0 3.38, phi-4 3.30, Qwen2.5-7B 3.07. Polish EQ-Bench: Mistral-Small-2409 72.85, Bielik-11B-v2.5 72.00, Qwen2.5-14B 69.17, Bielik-4.5B-v3.0 53.58. Same Bielik report.
- FACT: none of these benchmarks measures **summarisation faithfulness** in Polish. I found no published Polish meeting-summarisation benchmark.

#### 3.3 Speed, structured output, Apple's model

- FACT (secondary blogs, methods unclear): Qwen 2.5 14B 4-bit on an M4 Pro: 68 tok/s with MLX, 52 with llama.cpp. Qwen3-Coder-30B-A3B on a Mac mini M4 Pro 64 GB: about 130 tok/s with MLX vs 43 through Ollama's old llama.cpp backend. MLX is reported 1.4-1.8x faster at decode, with the advantage shrinking at long contexts. https://yage.ai/share/mlx-apple-silicon-en-20260331.html and https://aiagentskit.com/blog/mlx-vs-llama-cpp-apple-silicon/ (snippets, 2026).
- UNVERIFIED today (background knowledge): llama.cpp constrains output with GBNF grammars and converts JSON Schema to a grammar. https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md (not re-fetched).
- FACT: Apple's Foundation Models framework. The on-device model has a 4,096-token context that covers instructions, prompts, tool definitions, schemas and responses; `contextSize` is readable at run time; some sources report 8,192 on OS 27 (conflicting). Guided generation (`@Generable`, `@Guide`) is constrained decoding. https://artemnovichkov.com/blog/tracking-token-usage-in-foundation-models and https://deployedwork.com/writing/apple-foundation-models-primer (snippets, 2026).
- FACT: **Polish is not an Apple Intelligence language.** macOS 27 list: English, Danish, Dutch, French, German, Italian, Norwegian, Portuguese, Spanish, Swedish, Turkish, Vietnamese, Chinese (Simplified, Traditional), Japanese, Korean. https://support.apple.com/en-us/121115 (fetched; published 2026-11-05). A developer-forum thread reports `SystemLanguageModel` unavailable when the device language is unsupported, Polish included: https://developer.apple.com/forums/thread/805378 (snippet).

#### RECOMMENDATION (LLM)

1. The step up from Qwen3-4B that fits 16 GB is a **12B-class model at Q4 (about 7 GB)**: Gemma 4 12B or Bielik 11B v3.0. On 32 GB and more, add Gemma 4 26B A4B (MoE, about 14 GB, fast because only 4B are active). Benchmark these three on your own Polish gold set; no public number answers the faithfulness question.
2. Bielik is the only family with strong, published Polish scores, but the HF repo is gated, which complicates an in-app download with pinned hashes. Check redistribution terms before putting it in `LLMModelCatalog`.
3. Tier the catalogue by RAM (4B / 12B / 26B-A4B) instead of one model for everyone.
4. Do not use Apple's on-device model for Polish notes: no Polish, and 4K context. It could serve English-only short tasks (title, tags) as a zero-download option.
5. Disable thinking mode for extraction passes on Qwen3.x, or budget for it; it costs tokens and time on long transcripts.

---

### 4. Notes pipeline for 60-120 minute transcripts

#### What published work says

- FACT: hierarchical merging (summarise sections, then merge summaries) **amplifies hallucination**; giving the merge step source context helps. Three ways were tested: replace intermediate summaries with retrieved input, refine them against the context, or align them through citations. Refinement paired with extractive summarisation worked best, with Llama 3.1 models. https://arxiv.org/abs/2502.00977 (fetched; Ou and Lapata, ACL 2025 Findings).
- FACT: on topic-focused dialogue summarisation (TofuEval), LLMs of all sizes make many factual errors; LLMs used as binary factuality judges, GPT-4 included, do poorly and specialised non-LLM factuality metrics can beat them. https://arxiv.org/abs/2402.13249 (fetched; NAACL 2024). **Older**, but the only meeting-style faithfulness benchmark I verified.
- FACT: a multi-stage pipeline (FRAME/SCOPE) cut hallucination on QMSum from 3 to 1 on a 5-point MESA scale. https://aclanthology.org/2025.findings-emnlp.1094.pdf (snippet, EMNLP 2025 Findings).
- FACT: segment-level tree search for long meetings: segment summaries, concatenation, then a refinement pass; evaluated on QMSum. https://arxiv.org/pdf/2606.08445 (snippet, 2026).
- FACT: MiniCheck checks one sentence against a grounding document; the 770M FT5 version reaches GPT-4 accuracy on LLM-AggreFact (11 human-annotated datasets). https://arxiv.org/abs/2404.10774 (snippet, EMNLP 2024). Bespoke-MiniCheck-7B is a larger successor: https://huggingface.co/bespokelabs/Bespoke-MiniCheck-7B (snippet). **Polish support UNVERIFIED**; these were trained on English.
- FACT: QMSum has 1,808 query-summary pairs over 232 meetings and proposes locate-then-summarise. https://arxiv.org/pdf/2104.05938 (snippet, 2021).
- FACT: no accepted public benchmark exists for action items with owner and due date. Open-source projects report F1 on small synthetic sets (for example 152 items, or 27 gold items in 5 meetings), and several add a verifier that rejects owners and dates not present in a quoted span. https://signaltosummary.com/posts/action-item-extraction-from-meeting-transcripts and https://github.com/ronakchaurasiya805/meeting-notes-summariser (snippets).
- UNVERIFIED today (background knowledge, not re-fetched): Chain of Density (arXiv 2309.04269), BooookScore on hierarchical vs incremental (2310.00785), FABLES (2404.01261), Summary of a Haystack (2407.01370), FActScore (2305.14251), AlignScore (2305.16739), SummaC (2111.09525), FineSurE (2407.00908), MeetingBank (2305.17529), the ELITR Minuting Corpus and the AMI corpus.

#### RECOMMENDATION (pipeline)

Use **extract-then-abstract with citations**, not plain map-reduce:

1. **Segment** by topic or time (about 5-8 minutes, speaker turns intact) with stable ids and timestamps.
2. **Extract per segment** into a strict schema under a grammar: decisions, action items (`task`, `owner`, `due`, `evidence_quote`, `segment_id`), open questions, key facts. Require a verbatim quote for every item. Owner and date must appear in the quote or in neighbouring turns, otherwise the field stays null. Give the model the speaker list and the meeting date so "I'll do it" and "by Friday" can be resolved.
3. **Verify in code first**: fuzzy-match each quote against the segment (cheap, language-independent, catches most invention). Then an optional entailment pass with the same LLM asked a yes/no question per claim. Drop or flag what fails.
4. **Merge** with deduplication over the extracted items, never over prose summaries. The reduce step sees items plus their quotes, which is the "context-aware" variant that Ou and Lapata found safer.
5. **Write** the final notes from the verified items only. Keep `segment_id` and timestamps on each bullet so the UI can link back.
6. Write Polish notes from Polish evidence. Do not translate through English.

Skip Chain of Density for meetings: it optimises density, and your problem is faithfulness and missing owners.

---

### 5. Hybrid notes (Granola-style)

- FACT: Granola's enhanced notes use three inputs: the transcript, the user's raw notes and calendar event information. Enhancement runs when the call ends or on demand. https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes (fetched).
- FACT: the user's raw text stays visually distinct (shown in black) from AI text; a magnifying glass next to each note shows where it came from in the transcript or the raw notes. Same source.
- FACT: templates define sections, level of detail and format; users can write custom templates with their own prompt; "recipes" are saved prompts run after enhancement; editing one note does not change future notes; editing the raw notes and regenerating does take the edits into account. Same source and https://www.granola.ai/blog/meeting-recipes-repeatable-formats (snippet).
- FACT: Granola says it uses "a blend of models, primarily from OpenAI and Anthropic". Same docs page.
- FACT: audio is cached only during the meeting for transcription and then deleted; notes and transcripts are stored on AWS in the US; consent is the user's responsibility. https://docs.granola.ai/help-center/consent-security-privacy/security-privacy-data-faqs (fetched).
- FACT: reviewers describe the behaviour as "using your bullets as anchors": topics the user wrote down are prioritised and filled in from the transcript; with no typed notes it falls back to the transcript alone. https://zackproser.com/blog/how-does-granola-ai-work (snippet; third-party).
- FACT: **Granola has not published how notes are aligned with the transcript.** I found no engineering write-up. Timestamp alignment is an inference from the product behaviour.

#### RECOMMENDATION (hybrid notes)

Record a timestamp for each line the user types (and for later edits). At enhancement time, retrieve the transcript window around each line (for example 60 s before to 30 s after, since people type after hearing), and treat the user's lines as required headings: every one must appear in the output, expanded with cited evidence. Then run the section 4 extraction for the rest and place it under "also discussed". Keep user text visually distinct and never rewrite it silently.

---

### 6. Ask-your-archive

#### Embeddings for Polish

- FACT: on PIRB (41 Polish retrieval tasks, NDCG@10): Qwen3-Embedding-8B 60.93, 4B 59.19, **0.6B 50.71**; Polish-specific stella-pl-retrieval-8k 62.69 and its mini variant 61.29. https://arxiv.org/pdf/2609.12913 (snippet; Sept 2026). The stella-pl scores may be inflated by overlap between training and evaluation data (PL-MTEB authors' warning).
- FACT: the same paper releases **PolDense** (six Polish retrievers, 17M to 1B parameters) and **EuroDense** (435M, nine European languages), both with 8,192-token context; PolDense-1B is reported to beat retrievers up to 9B. https://arxiv.org/abs/2609.12913 (fetched). Licence and exact scores UNVERIFIED.
- FACT: PL-MTEB (ACL 2026 Findings): Qwen3-Embedding-8B has the best average; Qwen3-0.6B averages 66.93. https://aclanthology.org/2026.findings-acl.1773.pdf (snippet).
- UNVERIFIED today: Polish retrieval scores for bge-m3, multilingual-e5 and EmbeddingGemma; EmbeddingGemma's size, context and licence.

#### Storage and search

- FACT: the sqlite-vec maintainer describes hybrid search as one FTS5 table and one `vec0` table sharing a rowid, fused with reciprocal rank fusion. https://github.com/asg017/sqlite-vec/issues/48 (snippet).
- FACT: RRF scores each result 1/(k + rank) per list and sums; k = 60 is the usual choice. On BEIR SciFact a SQLite hybrid scored 0.866 vs 0.840 vector-only and 0.816 FTS5-only, at about 3.5 ms p50. https://github.com/mycman/sqlite-vec-benchmark (snippet; a personal repo, metric column not captured).
- FACT: sqlite-vec used brute-force scans rather than an ANN index in 2025. https://github.com/asg017/sqlite-vec (snippet; possibly outdated).
- FACT: loading sqlite-vec into GRDB with a custom SQLite build means compiling its C source into the amalgamation and registering it with the auto-extension hook. https://github.com/groue/GRDB.swift/discussions/1761 (snippet).
- FACT: **I found no source showing sqlite-vec + SQLCipher + GRDB working end to end.** Compatibility is UNVERIFIED.

#### MCP

- FACT: Granola's official remote MCP server (`mcp.granola.ai`) exposes `query_granola_meetings`, `list_meetings`, `get_meetings`, `get_meeting_transcript`, and in one listing `list_meeting_folders` and `get_account_info`; transcripts need a paid plan. https://www.usecarly.com/blog/granola-mcp/ (snippet; third-party, tool count differs between sources).
- FACT: Fireflies' official MCP server (`api.fireflies.ai/mcp`) covers searching, retrieving and managing transcripts, summaries, soundbites, channels and user data; some tools write (share a meeting, create a soundbite); catalogues count 18-19 tools. https://docs.fireflies.ai/mcp-tools/overview (snippet).
- FACT: stdio servers talk only to the client process that launched them, so a web page has no port to attack; a localhost HTTP server is exposed to DNS rebinding unless it validates Origin and Host, binds to 127.0.0.1 and requires a token. stdio does not sandbox the server's own file or credential access. https://cheatsheetseries.owasp.org/cheatsheets/MCP_Security_Cheat_Sheet.html (snippet).

#### RECOMMENDATION (archive)

1. Ship **FTS5 first** (you already have folded Polish FTS in `meetings.sqlite`), add vectors second. For a personal archive (thousands of chunks) a brute-force cosine scan over float blobs in the encrypted database is fast enough and avoids the unverified sqlite-vec + SQLCipher combination.
2. Evaluate PolDense (small sizes) against Qwen3-Embedding-0.6B and bge-m3 on your own questions. The 0.6B Qwen model is clearly weaker on Polish retrieval than Polish-specific models.
3. Answers must cite meeting, timestamp and quote, verified by the same quote match as in section 4.
4. MCP: stdio transport only, started by the user's assistant, read-only tools (`list_meetings`, `search`, `get_notes`, `get_transcript` with a size limit), off by default, with a visible indicator and a per-client allow list. The key stays in the Keychain and the helper asks the running app for data; do not hand the database key to a second binary. Transcript text returned to an assistant is untrusted input that can carry prompt injection, and it may leave the Mac if the assistant is a cloud model; say so in the UI.

---

### 7. Meeting detection, capture and consent

- FACT: Core Audio process taps (`CATapDescription`, `AudioHardwareCreateProcessTap`) capture the output of one process or a group; sources give macOS 14.2 as the minimum (one sample project says 14.4). The tap is wrapped in an aggregate device with an IO proc. A denied permission can show up as zero-filled buffers, not an error. https://github.com/insidegui/AudioCap and https://pypi.org/project/catap/0.2.0/ (snippets); Apple forum thread on silent buffers: https://developer.apple.com/forums/thread/825780 (snippet). Apple's own article was not retrieved; the Info.plist key name is UNVERIFIED.
- FACT: detecting a call: enumerate `kAudioHardwarePropertyProcessObjectList`, read `kAudioProcessPropertyIsRunningInput` and the bundle id per process, match against a meeting-app allow list, exclude your own PID. One project rejected the device-level flag (`DeviceIsRunningSomewhere`) because it misfires. https://macnotetaker.com/blog/which-app-is-using-mic-coreaudio-process-objects and https://github.com/yazinsai/OpenOats/issues/726 (snippets, 2026).
- FACT (single reports, unconfirmed by Apple): property listeners on `IsRunningInput` register but never fire on macOS 26.6.2, while reads still work, so polling is the fallback; and polling at a high rate made `coreaudiod` issue about 13 TCC checks per second in one app. https://github.com/silverstein/minutes/issues/1127 (snippet).
- FACT: dictation apps holding the microphone trigger false meeting detections when only "mic in use" is checked. OpenOats issue above.
- FACT: Granola offers an optional pinned chat message ("Hey, I'm using www.granola.ai to transcribe and take notes.") and a watermark; both are off until enabled; admin enforcement and a participant notification pilot ("Heads Up") are Enterprise only. https://docs.granola.ai/help-center/consent-security-privacy/transparency-solutions/introduction and https://www.getvoibe.com/resources/is-granola-safe/ (snippets).
- FACT: a US class action, *Chamberlain v. Granola, Inc.*, alleges recording of participants who did not consent. https://blog.buildbetter.ai/do-they-own-your-data-granola-ai-privacy-policy-reviewed/ (snippet; competitor blog, case status UNVERIFIED).
- FACT (Polish law, secondary sources, **not legal advice**): law-firm articles agree that a participant who records their own conversation does not commit the offence in art. 267 KK, because the content is meant for them; recording other people's conversation without taking part can. Such recordings are generally admissible as evidence. Recording or publishing can still infringe personal rights (privacy) under civil law. GDPR does not apply to purely personal use, but does when a company or employer records. https://adwokatura-bialystok.pl/index.php/2026/05/05/nagrywanie-rozmow-bez-zgody-gdzie-konczy-sie-ostroznosc-a-zaczyna-odpowiedzialnosc-prawna/ and https://zaufanyprawnik.pl/poradniki/co-grozi-za-nielegalne-nagrywanie-rozmow (snippets). The case number cited by one blog (VI ACa 1068/14) is UNVERIFIED.
- FACT: US federal law is one-party consent; about a dozen states require all parties to consent for at least some recordings. BuildBetter blog above (secondary).

#### RECOMMENDATION (detection and consent)

1. Detect with the per-process input flag plus a bundle-id allow list (and browser tab heuristics only if the user grants Accessibility), poll at 1 Hz at most, and **suggest** recording; never start silently.
2. Add calendar context through EventKit for the title and attendees.
3. Ship a one-click "copy consent message" and a first-run notice that explains work use (GDPR applies; the employer may be the controller) and all-party-consent jurisdictions. Being fully local is a real advantage: no processor, no transfer, no training.

---

### 8. Evaluation

#### Facts

- FACT: single-trial LLM judging is noisy. Over 29 tasks, with 50 pairwise and 50 pointwise trials per question on two OpenAI judges: pairwise verdicts flipped 13.6% of the time on average (28% of questions above 20%); first-position bias (72% A-majority for GPT-4o-mini); two judges agreed 76% of the time (kappa 0.51); equivalent prompt wordings changed the majority outcome in 25% of cases; about **11 repeated trials** were needed for the majority vote to match the 50-trial verdict with 95% probability (15 for high-variance questions); temperature 0 reduces but does not remove the noise. https://arxiv.org/abs/2606.13685 (fetched; 2026-04-23; single author, both judges from one vendor).
- FACT: a panel of several smaller judges from different model families beat a single large judge across six datasets, with less intra-model bias and over seven times lower cost. https://arxiv.org/abs/2404.18796 (fetched; Verga et al., 2024).
- FACT: for sentence-level factuality in dialogue summaries, specialised metrics can beat LLM judges. TofuEval, section 4.
- FACT: MeetEval computes cpWER, tcpWER (cpWER with a time constraint), ORC-WER (ignores speaker labels) and DER wrappers, with a CLI. https://github.com/fgnt/meeteval and https://arxiv.org/abs/2307.11394 (snippets). cpWER can be zero while timestamps are wrong, so pair it with tcpWER or DER (https://aident.ai/blog/wer-cpwer-speaker-assignment-test, snippet).
- FACT: WDER is the share of words tagged with the wrong speaker, counted on correctly recognised and substituted words only. https://arxiv.org/html/2409.00151v1 (snippet).
- FACT: human-human agreement on pairwise preference is cited as about 0.63 with ties and 0.81 without (Zheng et al. 2023, via https://arxiv.org/pdf/2606.21930, snippet). I found no published guidance on the size of a human calibration set.

#### RECOMMENDATION (evaluation)

1. **Gold set**: 8-12 real meetings (Polish, English, mixed; 2-6 speakers; 20-90 minutes), each with a corrected transcript with speakers, a list of key points (10-25 atomic statements), decisions, and action items with owner and due date. Annotate once; it pays for every later comparison. The size is my judgement, not a published figure.
2. **Transcript metrics** (deterministic, no judge): WER with one fixed Polish normaliser; error rate on a list of English jargon terms; tcpWER and WDER for speaker attribution; DER; and the share of segments containing more than one reference speaker, which is your 15-20% figure measured directly.
3. **Notes metrics, claim-level instead of holistic scores**:
   - coverage = gold key points found in the notes (recall);
   - faithfulness = note claims supported by the transcript (precision), checked per claim against the cited span;
   - action-item F1 with three levels: task matched, task + owner, task + owner + due.
   Counting yes/no decisions over 100-300 claims gives far less variance than one 0-100 score per meeting.
4. **Judge noise**: use a panel of two or three judges from different families, a majority of at least 5 repeats for each binary decision on disputed items, randomised order, a frozen judge prompt, and paired comparison of two systems on the same meetings with a bootstrap confidence interval. Calibrate the judges once against your own labels on about 100-200 claims and report agreement.
5. **Local regression gate**: transcript metrics on every change (minutes, no LLM); the notes gate with a local judge (the largest model the machine holds) for claim checks plus string checks for quotes, owners and dates; cloud judges only for release decisions and never on private meetings without consent.

---

### Gaps I could not close

- No public Polish-English code-switching ASR benchmark and no Polish meeting-summarisation faithfulness benchmark.
- No real-world Polish numbers for Nemotron Unified ASR, Parakeet Ultra/Redux or Nemotron 3.5 Transcribe Lite; no FluidAudio DER for Nemotron 3 Diarization.
- Licences and specs marked UNVERIFIED above (Parakeet v3, Canary 1B v2, Whisper, pyannote, Phi-4, gpt-oss-20b, EmbeddingGemma, PolDense, Qwen3.6, Llama 4, Granite 4.x, PLLuM).
- Apple's own documentation for process taps and for `SpeechTranscriber.supportedLocales` was not retrieved; check both on a Mac running the current OS.
- sqlite-vec with SQLCipher under GRDB is untested in any source I found.
- Legal points come from law-firm and vendor blogs. Check primary law and dockets before relying on them.


---

# CZĘŚĆ C: niezależna weryfikacja twierdzeń o Claude Meetings (2026-11-13)

Trzy strony Anthropic pobrane ponownie (HTTP 200): [A] https://claude.com/resources/articles/claude-meetings , [H] https://support.claude.com/en/articles/18325154-use-claude-meetings , [R] https://support.claude.com/en/articles/12138966-release-notes

| Twierdzenie | Wynik | Dowód |
|---|---|---|
| Beta „Claude Meetings” | POTWIERDZONE dla 2026-11-12 (data 11-10 tylko z prasy) | [A] „Introducing Claude Meetings, now in beta.”; [R] „Claude Meetings is rolling out in beta on Team and Enterprise plans in Claude and Claude Desktop.” |
| Widoczny uczestnik, tylko Google Meet | POTWIERDZONE | [H] „lets you add Claude to a Google Meet call as a visible participant”; [A] „Support is currently available for Google Meet, with other platforms coming soon.” Słowo „bot” nie pada na stronach Anthropic. |
| Plany Team i Enterprise | POTWIERDZONE; „nie ma w Free/Pro/Max” to wniosek z pominięcia, strony tego nie mówią | [H] |
| Zapis: transkrypt, podsumowanie, opisy ekranu, bez audio | POTWIERDZONE | [A], [H] „It saves a transcript, summary, and screen descriptions, not audio.” |
| Do ośmiu godzin | POTWIERDZONE (tylko [H]) | „Claude can stay for up to eight hours and warns you before it leaves.” |
| Pytania o przeszłe spotkania w czacie | POTWIERDZONE | [H], [A] |
| Goście zewnętrzni | POTWIERDZONE, łącznie ze sprzecznością obu stron co do domyślnego ustawienia w planie Team | [A] vs [H] |
| Języki (polski), etykiety mówców, retencja, trening, cena po becie | BRAK NA STRONACH | — |
| „Parka” (lokalny rejestrator w Claude Desktop) | Brak źródła pierwotnego; tylko doniesienia z sierpnia 2026 z analizy buildów | RuntimeWire, Reworked i pochodne |
