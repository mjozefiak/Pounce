# Meeting-notes market survey (B) — 2026-11-13

Scope: competitive survey for a privacy-first, fully on-device macOS meeting-notes feature (microphone + system audio, no bot, local transcription and diarization, encrypted storage, local LLM notes; Polish and English).

## How to read this document

- **FACT** = stated on a page I fetched or in a search result, with URL and date. "Primary" means the vendor's own page; "secondary" means press or a third-party blog.
- **INFERENCE** = my conclusion from the facts.
- **UNVERIFIED** = a claim I found only in secondary sources, in conflicting sources, or could not open.
- Research date: 2026-11-13. All "as of" statements refer to that date.
- Source quality warning: most competitor reviews in this market are written by other vendors (tl;dv, Anarlog, Voibe, Noter AI, Jamie, Circleback, Shadow all publish "reviews" of rivals). I mark these. Prices from review blogs conflict often; only the Granola price table below comes from the vendor's pricing page.
- Not done: I did not open Reddit, X or G2 threads directly (search returned almost none of them); user-sentiment evidence below is therefore mostly second-hand and is marked as such. I could not open OpenAI's help article (HTTP 403).

---

## Part 1 — Anthropic / Claude

### 1.0 Short answer

| Item | Status | What it is |
|---|---|---|
| **Claude Meetings** | **SHIPPED (beta)**, announced 2026-11-10, beta rollout 2026-11-12 | A **visible bot participant** that joins **Google Meet** calls, takes notes, answers questions in chat and builds docs/whiteboards during the call. **Team and Enterprise only.** Cloud. |
| **"Parka" desktop recorder** | **RUMOURED / leaked, not shipped, not confirmed** (reports 2026-08-19 to 2026-08-25) | A Mac-first recorder inside Claude Desktop that captures system audio + microphone without a bot, with speaker-attributed live transcript and action items routed to Cowork / Claude Code. Disabled stub in public builds. |
| Voice mode, dictation | SHIPPED | Speech input for chats. Not a meeting recorder. Polish is **not** in the published dictation language list. |
| Meeting-tool connectors (Granola, Fireflies, Otter, Fathom, tl;dv, Circleback) | SHIPPED (third-party connectors in Claude's directory) | Claude reads transcripts and notes that those tools captured. Claude does not record. |
| `sales:call-summary` skill (knowledge-work plugins) | SHIPPED | Turns a pasted or connected transcript into a summary, follow-up email and CRM updates. No capture. |
| Transcript export from Claude Meetings to Gong, Attention, Granola, Fireflies.ai, Otter (and Plaud per one reading) | ANNOUNCED ("soon") | Not available yet. |
| More video platforms for Claude Meetings | ANNOUNCED ("coming soon", no names, no dates) | Not available yet. |

So the thing Anthropic actually ships today is the opposite architecture to ours: a cloud bot, for teams, on one platform. The architecture that would compete with us directly (Parka: local capture on the Mac) is unreleased and unconfirmed.

### 1.1 Claude Meetings — SHIPPED (beta)

Sources (primary):
- Launch article "Introducing Claude Meetings", claude.com, dated 2026-11-12: https://claude.com/resources/articles/claude-meetings
- Help Center setup article: https://support.claude.com/en/articles/18325154 (fetched 2026-11-13)
- Release notes, entry 2026-11-12: https://support.claude.com/en/articles/12138966-release-notes

Sources (secondary):
- TechCrunch, 2026-11-10: https://techcrunch.com/2026/11/10/anthropic-launches-claude-meetings-to-turn-workplace-discussions-into-plans-and-tasks/
- VentureBeat, 2026-11-12: https://venturebeat.com/technology/anthropic-brings-claude-into-google-meet-to-draft-documents-and-whiteboards-during-your-meetings
- The Decoder, 2026-11-12: https://the-decoder.com/claude-meetings-lets-anthropics-ai-join-your-video-calls/
- Trending Topics, 2026-11-10: https://www.trendingtopics.eu/claude-meetings-anthropic-video-calls-collaboration/
- Independent analyses: https://vanja.io/claude-meetings/ , https://cellcog.ai/blog/claude-meetings/ , https://dev.to/lycore/claude-can-join-your-google-meet-now-7-questions-id-ask-before-auto-join-2ll4 (2026-11-13)

Timeline (FACT): announced on Tuesday 2026-11-10 together with Claude Whiteboards, Claude Sheets, Claude Data (GA) and interactive connectors (TechCrunch). The release notes record the beta on 2026-11-12. One analysis notes the 11-10 post said "coming soon" (vanja.io).

| Aspect | Finding | Label |
|---|---|---|
| What it does | Claude joins the call as a visible participant, follows the conversation, writes notes and action items, answers questions asked aloud or in chat (answers are written in the Meet chat; it does not speak), and builds docs, whiteboards and slides with attendees during the call. | FACT (launch article, release notes, Help Center) |
| Audio capture | **Bot.** Claude has its own participant tile and posts a notice in the call chat when it joins. No local or system-audio capture. | FACT (launch article; Help Center) |
| Where transcription runs | Cloud (a server-side participant). The pages name no speech provider. | INFERENCE from the bot design; provider UNVERIFIED |
| Platforms | **Google Meet only.** "Other video conferencing platforms" are "coming soon", with no names or dates. Works in Claude (web) and Claude Desktop; mobile is not mentioned. No in-person capture, no Zoom, no Teams, no phone calls. | FACT (Help Center) |
| Plans | **Team and Enterprise only.** Free, Pro, Max and Ultra are not included; Anthropic has not said whether they will be. | FACT (Help Center); the exclusion of individual plans is as reported by vanja.io, dev.to |
| Requirements | Google Calendar connector enabled by an owner. Not available to organizations with zero data retention, the HIPAA-ready configuration or customer-managed encryption keys. | FACT (Help Center) |
| Pricing | Notes, transcripts and in-call answers are included during the beta, unless an answer uses a connected tool (counts toward plan usage and can lead to charges). Docs, whiteboards and other artifacts made in a call are free through 2027-02-10. No post-beta price published. Team seats are $20/user/month annual or $25 monthly (VentureBeat citing claude.com/pricing). | FACT |
| What is saved | "a transcript, summary, and screen descriptions, not audio". Each meeting gets a page in claude.ai with summary, action items, transcript and artifacts. Organization members on the invite get a recap email. | FACT (launch article; Help Center) |
| Speaker identification | Not described. The only documented behaviour: for spoken requests, "Claude asks each time to confirm who's speaking". Whether transcripts are labelled per speaker is not documented. | FACT for the confirmation step; the rest is **not documented** |
| Languages | **Not stated anywhere** (launch article, Help Center, press). Polish support is unknown. | Nothing conclusive |
| Templates | None mentioned. | Nothing found |
| Action items | Yes, on the meeting page. | FACT |
| Q&A over past meetings | Users can ask Claude follow-up questions about meetings they attended (VentureBeat; cellcog.ai). Cross-meeting search details are not documented. | FACT (secondary) |
| Sharing | Organization members on the invite can view notes and edit what Claude made; the page can be shared inside the organization. External guests get no page and no recap. | FACT (Help Center) |
| External guests | Enterprise: Claude stays out unless an owner allows it, and leaves if an outsider joins. Team: the Help Center says guests are **allowed by default** (an owner can turn it off), while the launch article says Claude stays out "by default". When allowed, Claude takes notes and posts its notice but does not reply in chat; guests' speech is in the notes and transcript. | FACT, with a documented contradiction between the two primary pages (vanja.io) |
| Auto-join | Per user: all meetings, or all except one-on-ones. Owners cannot set it for users. If the host declines, Claude does not retry. | FACT (Help Center) |
| Duration | Up to eight hours, with a warning before it leaves. | FACT (Help Center) |
| Consent | Anthropic asks teams to confirm everyone is comfortable being transcribed before adding Claude or turning on auto-join. | FACT (launch article) |
| Retention, deletion | **No retention period and no per-meeting deletion procedure published.** | Nothing conclusive (noted by vanja.io, dev.to, Trending Topics) |
| Training on meeting data | Not addressed in the Meetings pages. Secondary sources say Anthropic's commercial plans (Team, Enterprise, API) are excluded from training by default; I did not open the primary privacy page. | UNVERIFIED for Meetings specifically |
| API / MCP / webhooks for meetings | None found. | Nothing found (vanja.io) |
| Roadmap hints | Transcript hand-off to Gong, Attention, Granola, Fireflies.ai, Otter "soon" (one reading of the launch article also lists Plaud). Axios is reported to say Anthropic expects Claude to become more proactive in meetings. | ANNOUNCED / secondary |

Known limitations (all FACT from the pages above): Google Meet only; team plans only; visible bot; no audio kept (notes cannot be checked against audio); spoken requests need a speaker confirmation each time; in-chat answers are visible to the whole call, including answers drawn from one person's connected tools; excluded for ZDR/HIPAA/CMEK organizations.

Early reactions:
- I found **no** r/ClaudeAI or Hacker News thread about Claude Meetings (the feature is one to three days old). One r/artificial post is cited second-hand as arguing that an AI drafting follow-ups mid-call "may be solving the wrong problem" — UNVERIFIED, link not retrieved.
- Blog commentary (dev.to, 2026-11-13) focuses on: the in-call notice is not advance consent, missing retention and deletion rules, Meet-only, and no access for individual plans.
- INFERENCE: individual users (Pro/Max) who want meeting notes from Anthropic have nothing first-party today.

### 1.2 "Parka" — RUMOURED desktop recorder (not shipped, not confirmed)

Sources (all secondary; originate from one reverse-engineering report):
- RuntimeWire, "Anthropic's Project Parka sits through meetings and assigns Claude agents the homework", 2026-08-19 (body behind a sign-in): https://runtimewire.com/article/anthropic-s-project-parka-sits-through-meetings-and-assigns-claude-agents-the-ho
- Reworked, 2026-08-25: https://www.reworked.co/digital-workplace/anthropic-explores-meeting-recorder-that-assigns-tasks-to-claude-agents/
- AI Insiders (citing RuntimeWire): https://aiinsiders.net/article/claude-desktops-hidden-parka-feature-would-staff-meetings
- Superpower Daily: https://superpowerdaily.com/posts/anthropic-s-unreleased-meeting-tool-could-hand-claude-the-follow-up-work
- I found no TestingCatalog, The Information or The Verge article on it.

What the reports say (UNVERIFIED — design found in code, not a working feature):
- Found in Claude Desktop build 1.32885.1 (macOS package with 2026-08-18 file dates). Public builds force the feature to "unavailable"; the native loader is a 551-byte stub; flipping the flags showed no UI.
- Capture: **system audio, microphone, or both**; macOS 13 or newer. That is bot-less local capture, the same model as Granola and as our feature. (AI Insiders' remark that ScreenCaptureKit fits is its own inference.)
- Live, speaker-attributed transcript with timestamps; a field named `hasVisionResolvedSpeakers` suggests speaker naming from on-screen participant cues was explored.
- Calendar metadata and "transcription keyterms" as inputs; create/edit/delete meetings; summaries and editable notes.
- Action items with title, description, owner, full prompt and an execution type: `cowork`, `code` or `manual`, plus an `autoRunnable` flag and an optional Claude session URL.
- Speech-to-text: Anthropic-controlled hosts named `stt-nova3` and `stt-flux-multi` resemble Deepgram model names; no SDK, hostname or credential ties it to Deepgram. So transcription would be **cloud**, not on-device — INFERENCE from the host names; not confirmed.
- Anthropic "did not respond to a request for comment" (Reworked, 2026-08-25).

Status on 2026-11-13: the release notes from June to November 2026 contain **no** desktop recorder entry. Two blog guides contradict each other (one says the Mac app records up to 4 hours, one says Claude has no recorder); I treat the "4 hours" claim as wrong or confused with ChatGPT Record, because nothing in Anthropic's release notes supports it. **Nothing conclusive on whether or when Parka ships.**

INFERENCE for planning: assume Anthropic can ship a bot-less Mac recorder at any time. Its differentiator would be the hand-off of action items to agents (Cowork, Claude Code), with cloud transcription. It would still not be on-device or offline.

### 1.3 Voice mode and dictation — SHIPPED, not a meeting feature

- Dictation on mobile, all plans; languages: English, French, German, Hindi, Italian, Japanese, Korean, Portuguese, Russian, Spanish, Turkish, Ukrainian (non-English in beta). **Polish is not listed.** Audio is deleted after conversion to text by default; consumer plans can opt in to share recordings. Source: https://support.claude.com/en/articles/10065434-use-dictation-on-claude-mobile (fetched 2026-11-13).
- Claude Academy says dictation is on web, mobile and desktop, and voice mode on mobile, web and desktop on every plan; voice mode does not detect the language automatically; voice mode is not available in Cowork. The page describes talking through a meeting after the fact, not recording one. Source: https://academy.claude.com/tutorials/how-to-choose-between-voice-mode-and-dictation
- Voice mode language list: third-party sources conflict (10 vs 18 languages). UNVERIFIED; I found no official list that includes Polish.

### 1.4 Connectors, skills and plugins — SHIPPED (Claude reads other tools' notes)

- Claude's connector directory lists meeting tools. Reported: Fireflies (first, August 2025, `https://api.fireflies.ai/mcp`), Granola (February 2026), Otter (April 2026, read-only), Fathom (read-only), and tl;dv (https://claude.com/marketplace/connectors/tldv). Circleback has an MCP server on every plan; whether it is in Claude's directory is disputed. Sources are vendor blogs: https://circleback.ai/blog/ai-meeting-notetakers-mcp-claude-chatgpt , https://fellow.ai/blog/ai-meeting-notetaker-claude-connector/ , https://tactiq.io/learn/ai-meeting-notetaker-with-claude-connector — UNVERIFIED in detail.
- Official `call-summary` skill in Anthropic's sales plugin (`/sales:call-summary`): summary, follow-up email draft and CRM updates from a transcript; optional recorder connectors (Gong, Fireflies, Zoom, Otter.ai). Source: https://github.com/anthropics/knowledge-work-plugins/tree/main/sales . I found no dedicated official "meeting notes" plugin.
- Related release notes (https://support.claude.com/en/articles/12138966-release-notes): Cowork on web and mobile (2026-07-07), Microsoft 365 connector calendar write tools (2026-07-07), Cowork in every conversation (2026-09-16), Claude Duet research preview (2026-10-21). None is a meeting recorder.

### 1.5 Reference point: OpenAI ChatGPT Record — SHIPPED

I could not open the primary article (https://help.openai.com/en/articles/11487532-chatgpt-record returned 403). The following is from secondary sources and partly conflicting:

| Aspect | Finding | Source |
|---|---|---|
| Capture | Bot-less: the user presses Record in the macOS app; microphone and system audio; no video | tl;dv review 2026-04-07 (competitor): https://tldv.io/blog/chatgpt-record-mode-for-meetings/ |
| Platform | macOS desktop app only; no Windows, iOS, Android, web | several secondary sources; OpenAI help article per search summary |
| Plans | Plus (announced on X: https://x.com/OpenAI/status/1945547821626913059), Pro, Business, Enterprise, Edu. Older reviews say Team only. | conflicting secondary |
| Duration cap | 120 minutes per session in most sources; one says up to 240 | UNVERIFIED |
| Languages | "up to 50 languages", works best in English (2025 report). Polish quality unknown. | UNVERIFIED |
| Speakers | No speaker labels at launch (tl;dv review). Current state unknown. | UNVERIFIED |
| Output | Live transcript, then an editable summary in a canvas with time-stamped citations and suggested action items; searchable; can be referenced in later chats | secondary |
| Retention | Audio deleted after transcription; transcripts follow workspace retention; Enterprise/Edu transcripts reachable through the Compliance API | secondary: https://getweeve.io/blog/what-chatgpt-record-mode-does-with-your-meeting |
| Complaints | No audio to verify the summary, no speaker labels, nothing if you forget to press Record, meeting content mixing with chat memory, sharing only inside the workspace | tl;dv review (competitor) |

INFERENCE: a model vendor's meeting notes are a thin capture layer whose value is the hand-off to the vendor's assistant (canvas, memory, agents). Both OpenAI (shipped) and Anthropic (Parka, leaked) point to bot-less Mac capture with cloud transcription; neither is on-device, and neither documents Polish quality or speaker naming.

---

## Part 2 — Competitors

Legend for "Polish": **Yes** = on the vendor's published list; **No** = vendor's list omits it; **?** = not found.

### 2.1 Granola (the reference product)

- **Capture**: bot-less, device system audio + microphone on macOS and Windows; iOS/Android for in-person and phone calls; Apple Watch app. Captures the whole system audio stream (music can end up in the transcript; cannot isolate one app). Primary: https://docs.granola.ai/help-center/taking-notes/transcription
- **On-device vs cloud**: cloud. Audio is streamed to a third-party transcription provider (not named); "does not record or save audio or video at any point". Same page.
- **Speakers**: "Speaker tags" with meeting display names for Google Meet, Zoom and Teams on desktop (mechanism not explained); otherwise only **"Me" (microphone) and "Them" (system audio)**; mobile can separate speakers in person. Reviews report weak speaker identification with 3+ people (secondary).
- **Languages**: 31 on desktop, 17 on mobile. **Polish: mobile only — not available on desktop**, where online meetings are captured. Desktop multi-language mode handles several languages in one meeting; mobile picks one language per meeting. UI is English only. Primary: https://docs.granola.ai/help-center/customising-granola/multi-language (fetched 2026-11-13). Granola's own update "Granola now supports 32 languages": https://www.granola.ai/updates/granola-now-supports-32-languages
- **Hybrid notes**: yes, the defining feature (your typed notes are expanded with the transcript). Templates and "Recipes", voice typing in any app, shared folders, chat across meetings.
- **Integrations**: Slack on all plans; Attio, Notion, HubSpot, Affinity, Zapier on Business; Salesforce on Enterprise; MCP on all plans (Basic: personal notes from the last 30 days); API from Business.
- **Pricing** (primary, https://www.granola.ai/pricing, fetched 2026-11-13): Basic $0 with 30 days of history; Business $14/user/month; Enterprise $35/user/month.
- **Privacy**: SOC 2 Type II; audio deleted after transcription; model-training opt-out is per user on Basic and Business and workspace-wide on Enterprise (pricing page). The consent page says sub-processor agreements prohibit model training. Optional consent features: automatic chat notice and camera watermark (https://docs.granola.ai/help-center/consent-security-privacy/getting-consent); Enterprise has an "org-wide notification that Granola is in use" (pilot).
- **Legal**: *Chamberlain v. Granola, Inc.*, N.D. Cal. No. 3:26-cv-07926, filed 2026-07-30 by a non-user; Wiretap Act, CIPA §§ 631/632 and other claims; alleges capture without notice by default and training by default on Free and Business. Pleading stage, response was due 2026-10-12; current status not confirmed. Granola removed "No bot. No notification. No one else in the room." from its homepage (seen 2026-10-08). Secondary (a competitor's article with docket links): https://www.getvoibe.com/resources/granola-lawsuit/ ; docket: https://www.courtlistener.com/docket/73698016/chamberlain-v-granola-inc/
- **Funding**: reported $125M at $1.5B valuation in March 2026 (secondary review, UNVERIFIED).
- **Praise** (second-hand): no bot, native-feeling app, notes that read like your own, "seamlessly logged onto all my meetings without sending a bot". **Complaints**: silent capture failures (one founder: notes for about 60% of calls — single anecdote), no audio to check notes against, speaker identification, numbers and technical terms, back-to-back meetings merging, thin integrations, free tier limited to 30 days. Sources: https://anarlog.so/blog/granola-ai-complaints/ (competitor), https://www.aitooldiscovery.com/guides/granola-ai-reddit , https://www.happyscribe.com/blog/granola-ai-review (competitor).

### 2.2 Other products

| Product | Capture | Where it runs | Speakers | Polish | Notes model, search, integrations | Price (source quality) | Privacy, legal, complaints |
|---|---|---|---|---|---|---|---|
| **Fathom** | Bot by default; bot-free desktop capture reported as Mac first | Cloud | Names from the meeting platform (bot) | **Yes** on the help-center list (38 languages; page is old): https://help.fathom.video/en/articles/296192 . One vendor blog says Polish is limited to online calls | Templates, "Ask Fathom", CRM sync; API and MCP in 2026 | Free with unlimited recording and limited AI; Premium about $16–20/user/month (secondary, conflicting) | Most common complaint: the visible bot; no Android; weak in-person. Sources: https://www.laxis.com/blog/fathom-review/ , https://www.producthunt.com/products/fathom/reviews |
| **Otter.ai** | Bot (Notetaker) by default; bot-less desktop recording reported | Cloud | Voiceprint-style speaker identification | **No** — six languages (English, Spanish, French, German, Japanese, Mandarin) per several 2026 reviews | Live transcript, AI Chat across meetings, MCP server | Pro $16.99/month or $8.33 annual; Business $30 / $19.99 (secondary) | *In re Otter.AI Privacy Litigation*, N.D. Cal. 25-cv-06911-EKL: motion to dismiss granted in part and denied in part on 2026-08-13; ECPA, CIPA and Illinois biometric claims reported to survive (secondary: https://blog.buildbetter.ai/ai-notetaker-lawsuits-2026-how-to-record-meetings-legally/ ; text: https://caselaw.findlaw.com/court/us-dis-crt-n-d-cal/322025.html). Long-standing complaints about the bot joining uninvited: https://news.ycombinator.com/item?id=32751071 , https://news.ycombinator.com/item?id=44940554 |
| **Fireflies.ai** | Bot ("Fireflies Notetaker"); desktop/bot-free status not confirmed | Cloud | Speaker recognition (subject of a BIPA suit) | **Yes** (`pl`; 100+ languages; multi-language mode, beta, 60+ languages includes Polish): https://guide.fireflies.ai/articles/2973706448-learn-about-fireflies-supported-languages . One vendor blog rates its Polish "Limited" (UNVERIFIED) | AskFred chat, many integrations, first Claude connector | Free; Pro $10; Business $19; Enterprise $39 per user/month annual, AI credits capped per workspace (secondary) | *Fricker v. Fireflies.AI Corp.*, N.D. Ill. 1:26-cv-02675 (filed 2026-03-10, consolidated 2026-06-04), BIPA voiceprint claims; motion to dismiss filed 2026-07-15; no ruling reported by 2026-09-23 (secondary: https://allaboutlawyer.com/fireflies-ai-biometric-privacy-class-action-lawsuit-2026/) |
| **Krisp** | Bot-less, system-level audio | **English on-device; 15 other languages on servers** (krisp.ai FAQ per search) | Speaker identification on Core (single source) | **Yes, server-side** | Noise cancellation + notes | Core $8/month annual ($16 monthly); Advanced $15/$30 (secondary, Oct 2026); free tier status disputed | Polish audio leaves the device. Sources: https://krisp.ai/ , https://meetingcompare.com/pricing/krisp-pricing/ |
| **Notion AI Meeting Notes** | Bot-less in the desktop app (microphone + system audio); browser records the microphone only | Cloud | Speaker labels in **English only** (secondary) | **?** — "16 languages"; list not retrieved | Notes land in the Notion workspace; started manually per meeting; no auto-join | Business $20/member/month annual; since 2026-10-19 Notion AI uses monthly credits (secondary) | HN users note it records without alerting participants. Sources: https://scribbl.co/post/notion-ai-meeting-notes , https://tldv.io/blog/notion-ai-meeting-notes-review/ (competitor) |
| **Apple** (Notes, Phone, Apple Intelligence) | Notes records the microphone; Phone-app call recording saves to Notes with an audible alert to both sides (macOS 26). **No documented capture of system audio from third-party meeting apps.** | Transcription on-device (M1+); summaries by Apple Intelligence | None documented | **No** — transcription: English, Spanish, Portuguese, Italian, French, German, Japanese, Korean, Chinese. Apple Intelligence languages also omit Polish. | Summary button on a recording; no templates, action items or cross-meeting chat documented | Free with the OS | Primary: https://support.apple.com/guide/notes/record-and-transcribe-audio-apdb5106e334/mac (covers macOS 27 "Golden Gate", 26 and 15; fetched 2026-11-13); https://www.apple.com/newsroom/2025/06/macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/ . I found no WWDC 2026 announcement of a meeting recorder in Notes. |
| **Zoom AI Companion** | In-platform (Zoom meetings); cross-platform and in-person notes exist but details not verified | Cloud | Platform identity | **Unclear** — third-party lists of the 33 summary languages do not name Polish; Zoom's Custom AI Companion list includes Polish | Summaries, in-meeting questions, tasks | Included with paid Zoom Workplace (secondary) | Verify on Zoom's language page. Sources: https://news.zoom.com/breaking-down-boundaries-zoom-ai-companion-expands-language-support-across-its-platform-to-enable-better-global-collaboration-and-productivity/ , https://library.zoom.com/zoom-workplace/artificial-intelligence/artificial-intelligence-bluepaper/custom-ai-companion-explainer/features-and-architecture |
| **Google Meet "Take notes for me"** | In-platform | Cloud | Platform identity | **No** — eight languages (English, French, German, Italian, Japanese, Korean, Portuguese, Spanish), one language per meeting | Notes into Google Docs; "Ask Gemini in Meet" | Eligible Workspace plans | Primary: https://support.google.com/meet/answer/14754931 , https://support.google.com/meet/answer/14925782 (page date not confirmed) |
| **Microsoft Teams Copilot / Intelligent recap / Facilitator** | In-platform | Cloud | Platform identity; voice profiles for rooms (not verified here) | **Mixed** — Polish listed for Copilot in Teams and video recap; **not** in audio recap (June 2026) or multilingual recap translation (nine languages, 2026) | Recap, tasks, Facilitator live notes | Microsoft 365 Copilot or Teams Premium licence | Message-center mirrors: https://mc.merill.net/message/MC1479506 , https://blog-en.topedia.com/2026/08/intelligent-meeting-recaps-in-teams-can-now-be-translated-into-other-languages/ |
| **Limitless (ex-Rewind)** | Was a pendant + desktop capture | Cloud | — | — | — | — | **Acquired by Meta on 2025-12-05.** Pendant sales stopped; Rewind capture disabled 2025-12-19; service ended in the EU, UK and other regions; existing owners supported through 2026; desktop/web can read old meetings but not record new ones. Secondary: https://becomefluent.io/blog/2026-05/what-happened-to-limitless-pendant/ , https://www.therundown.ai/tools/limitless . Lesson: a cloud notes product can vanish with its data path. |
| **Plaud** | Hardware recorders (Note $159, NotePin $159, NotePin S $179, Note Pro $189) and a desktop notetaker announced 2026-01-04 | Cloud | Speaker labels | **?** ("112 languages" claim not verified) | Templates, summaries, Ask | Starter 300 min/month free; Pro $99.99/year (1,200 min/month); Unlimited $239.99/year (secondary) | Subscription on top of hardware is the usual complaint (secondary). https://techcrunch.com/2026/01/04/plaud-launches-a-new-ai-pin-and-a-desktop-meeting-notetaker , https://www.getvoibe.com/resources/plaud-pricing/ |
| **Jamie** | Bot-less desktop app | Cloud, EU data residency; audio deleted after transcription | Speaker recognition ("about 95% on mobile", vendor-adjacent claim); voiceprint details not verified | **Yes** per vendor blog (100+ languages) | Notes, action items, chat | Free 10 notes/month; paid roughly €21–25 Plus and €39–47 Pro (conflicting secondary) | https://www.meetjamie.ai/blog/ai-note-taker (vendor), https://tldv.io/blog/meetjamie-alternatives/ (competitor) |
| **tl;dv** | Bot; a bot-free audio-only app reported in 2026 | Cloud; EU storage, optional US AI processing | Platform names | **Yes** on its list (30–40+ languages); one vendor blog rates its Polish "Good" (UNVERIFIED) | CRM sync, MCP/API/webhooks on Pro | Conflicting: Pro $18–29, Business $59–98 | Trustpilot 1.4/5 from 8 reviews (tiny sample). https://www.laxis.com/blog/tldv-review/ |
| **Circleback** | Bot or bot-less desktop app (macOS, Windows) | Cloud | Speaker labels with every capture method; recording saved | **?** ("100+ languages") | Action items, automations, MCP on every plan | Free (from August 2026, 30-day history); Pro $15; Business $25; Enterprise $35 (secondary) | SOC 2 Type II, HIPAA with BAA (secondary). https://circleback.ai/blog/circleback-alternatives (vendor) |
| **Anarlog (ex-Hyprnote; "Char" is now the team's other product)** | Bot-less device audio | **Local-first**: on-device STT on supported Macs (Soniqo, Apple Speech named); LLM: managed cloud (Claude Sonnet via OpenRouter), your own key, Ollama / LM Studio, Apple Intelligence | Diarization exists as a library; no speaker-labelling feature described | **?** | Granola-style notepad; local SQLite + plain files; Markdown export; local CLI and MCP server | Open source (MIT community app, 9.9k stars); paid Pro (Cloud), price not shown | **Storage is not described as encrypted** (local SQLite, plain recordings). Primary: https://github.com/fastrepl/anarlog (fetched 2026-11-13) |
| **Meetily** | Bot-less, microphone + system audio | **Fully local**: Whisper or Parakeet; LLM via Ollama or cloud keys | "Who said what" speaker identification is a **Pro** feature; community diarization unclear | **?** (depends on the model; no list) | Summaries; "Chat with Meetings" and calendar integration are "coming soon" | Community free (MIT, about 32.7k stars); Pro $10/user/month annual | **No encryption at rest mentioned.** Primary: https://github.com/Zackriya-Solutions/meetily (fetched 2026-11-13) |
| **MacWhisper** | Bot-less; automatic meeting recording (beta) with app detection | Local (Whisper, Parakeet) | Speaker diarization (beta) | Depends on the model (Whisper and Parakeet v3 cover Polish — INFERENCE, not a vendor claim I verified) | Transcription tool first; notes are light | One-time about €64 (secondary, checked 2026-10-30) | https://www.getvoibe.com/resources/macwhisper-review/ (competitor) |
| **Superwhisper** | Bot-less "Meeting Mode" | Local models offline or cloud | Disputed: one source says speaker labels, another says none | Depends on the model | Dictation first, light meeting notes | Pro $8.49/month, $84.99/year, $249.99 lifetime (secondary) | https://lumevoice.com/blog/macwhisper-vs-superwhisper/ |
| **Alter** | Bot-less, Mac only | Local transcription with "optimized Parakeet V3" and speaker identification; recordings and transcripts stored locally; local or cloud LLM | Speaker identification (vendor claim) | **?** (Parakeet v3 is multilingual — INFERENCE) | Notes plus a general Mac AI assistant | Free plan; paid from $240/year (secondary) | Vendor: https://alterhq.com/meetings , https://alterhq.com/blog/privacy-mac-meeting-recording-with-local-ai |
| **Shadow** | Bot-less, Mac only | On-device transcription (vendor claim) | Not verified | **?** | Local Markdown vault for agents and Obsidian; smart screenshots | Free tier; Plus $8/month annual, $12 monthly | Vendor blog: https://www.shadow.do/blog/best-bot-free-meeting-assistants-in-2026-shadow-granola-jamie-bluedot-compared |
| **Cluely** | Hidden overlay that listens and prompts the user live | Cloud | — | **?** | Real-time answers; notes are secondary | Pro $19.99/month; Pro + Undetectability $149.99/month | Reputation risk: 2025 breach reported to expose 83,000 users' data; CEO admitted inflating ARR (March 2026). Secondary: https://www.interviewcoder.co/blog/cluely-ai-review (competitor), https://tldv.io/blog/cluely-review/ (competitor) |

### 2.3 Polish — what vendors actually publish

| Product | Polish for online meetings on a Mac | Evidence |
|---|---|---|
| Granola | **No** (mobile only) | Primary docs table |
| Otter | **No** | 2026 reviews; six languages |
| Google Meet notes | **No** | Google help page (eight languages) |
| Apple Notes | **No** | Apple support page |
| Claude dictation | **No** | Anthropic support page |
| Claude Meetings | **Not stated** | — |
| ChatGPT Record | **Not stated** ("up to 50 languages", best in English) | secondary |
| Teams | Partly (Copilot yes; audio recap and recap translation no) | message-center mirrors |
| Zoom AI Companion | Unclear | conflicting |
| Krisp | Yes, but server-side (only English is on-device) | krisp.ai FAQ via search |
| Fireflies, Fathom, tl;dv, Jamie | Yes on the list | vendor pages |

Quality evidence for Polish: **I found no independent benchmark of Polish meeting transcription for any notetaker.** What exists is vendor numbers on different test sets (Soniox 1.25% WER, TalkNotes 13.2% WER, Sonix "85–99%", Happy Scribe "over 95%") and one vendor roundup (Noter AI, 2026-10-11, ranks itself first, no method): https://www.noterai.net/best/polish-meeting-transcription-app . That roundup makes one useful point: published accuracy is measured on clean read-aloud Polish, and it advises checking case endings by hand. Sonix warns that Polish/English code-switching segments need review: https://sonix.ai/accurately-transcribe-zoom-meetings-in-polish . Mixed-language handling: Granola desktop and Fireflies (beta) claim several languages in one meeting; Google Meet notes and Granola mobile take one language per meeting.

INFERENCE: Polish on the desktop is the largest gap in the market leaders (Granola, Otter, Google, Apple, and unknown at Anthropic and OpenAI). Nobody publishes credible Polish or Polish/English numbers.

---

## Part 3 — Synthesis

### (a) Features × products

Y = yes, N = no, P = partly, ? = not found. "Claude Meetings" is the shipped product; "Parka" is the leak.

| Feature | Claude Meetings | Parka (leak) | ChatGPT Record | Granola | Fathom | Otter | Fireflies | Krisp | Notion | Apple Notes | Jamie | Circleback | Anarlog | Meetily | MacWhisper | Alter |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| No bot in the call | N | Y | Y | Y | P (Mac) | P | N | Y | Y | Y | Y | P | Y | Y | Y | Y |
| Works with any app (Zoom, Teams, Slack, in person) | N (Meet only) | Y? | Y | Y | P | P | P | Y | Y | N (mic/phone only) | Y | Y | Y | Y | Y | Y |
| Transcription on-device | N | N? (cloud hosts) | N | N | N | N | N | P (English only) | N | Y | N | N | Y (option) | Y | Y | Y |
| Notes LLM on-device | N | N | N | N | N | N | N | N | N | P | N | N | Y (option) | Y (Ollama) | P | Y (option) |
| Encrypted local store (vendor claim) | n/a | ? | n/a | n/a | n/a | n/a | n/a | n/a | n/a | OS-level | n/a | n/a | N (not claimed) | N (not claimed) | ? | ? |
| Audio kept for verification | N | ? | N | N | Y (video) | Y | Y | Y | ? | Y | N | Y | Y | Y | Y | Y |
| Speaker names beyond me/them | ? | Y (planned) | N at launch | P (Meet/Zoom/Teams tags) | Y | Y | Y | P | P (English) | N | Y | Y | N | P (Pro) | P (beta) | Y (claim) |
| Polish for desktop meetings | ? | ? | ? | **N** | Y | **N** | Y | Y (server) | ? | **N** | Y | ? | ? | model-dependent | model-dependent | ? |
| Hybrid notes (typed + AI) | N | P (editable notes) | N | **Y** | N | N | N | N | Y | N | P | N | Y | N | N | P |
| Templates / recipes | N | ? | N | Y | Y | Y | Y | Y | Y | N | Y | Y | Y | Y | P | Y |
| Action items | Y | Y (routed to agents) | Y | Y | Y | Y | Y | Y | Y | N | Y | Y | Y | Y | P | Y |
| Ask across past meetings | P | ? | P | Y | Y | Y | Y | P | Y | N | Y | Y | P | N (coming) | N | P |
| MCP / API | N | ? | N | Y | Y | Y | Y | ? | P | N | ? | Y | Y (local) | N | N | ? |
| Free for one person | N (Team/Ent.) | ? | N (paid plans) | P (30 days) | Y | P | P | ? | N | Y | P | P | Y | Y | paid once | P |
| Works offline | N | N? | N | N | N | N | N | P | N | Y | N | N | Y | Y | Y | Y |

Cells marked from secondary sources carry the caveats given in Part 2.

### (b) What users love most (ranked by how often it appears in the evidence)

1. **No bot in the call.** The main reason given for choosing Granola; the visible bot is the most common complaint about Fathom, Otter and Fireflies. Evidence: https://www.aitooldiscovery.com/guides/granola-ai-reddit , https://www.laxis.com/blog/fathom-review/ , https://news.ycombinator.com/item?id=43053921 ("Please Stop Inviting AI Notetakers to Meetings"), https://news.ycombinator.com/item?id=44446916 .
2. **It just works without setup** — calendar-aware start, no per-meeting action. Praised for Granola; its absence is the complaint for Notion (manual start) and ChatGPT Record (nothing if you forget to press Record).
3. **Notes that read like the user's own** — Granola's hybrid model and templates.
4. **A generous free tier** — Fathom's free unlimited recording is its most-cited strength.
5. **A fast, native app** — Granola praised against "clunky Electron-based transcription bots" (second-hand quote).
6. **Hand-off to other tools** — CRM sync, Slack, and in 2026 MCP so Claude or ChatGPT can query past meetings (every major vendor added it; Product Hunt users complained Fathom was late).
7. **Local and private** — the selling point of Meetily (about 32.7k GitHub stars) and Anarlog (9.9k); star counts are FACT, and are the only hard evidence of demand for local-first that I found.

Caveat: I did not read the Reddit/G2 threads themselves; ranking is INFERENCE from review articles and HN titles.

### (c) What users hate most

1. **Being recorded without real consent; bots that join uninvited or spread through calendars.** Otter HN threads (2022, 2025) and the Otter class action; survey of 500 US workers cited as 65.3% saying consent was inconsistent or absent: https://www.reworked.co/digital-workplace/lawsuit-ai-notetaker-liability-risk-management/ . Note: bot-less tools do not escape this — Granola is being sued precisely for capture without notice.
2. **Silent capture failures** — finding out after the call that nothing was recorded (Granola), a free user's meeting skipped under load (tl;dv).
3. **Wrong or missing speaker attribution**, especially with 3+ people; "Me/Them" only outside Meet/Zoom/Teams (Granola); none at launch in ChatGPT Record.
4. **Notes that cannot be verified** — no audio kept (Granola, ChatGPT Record, Claude Meetings), so hallucinated summaries are hard to catch; errors in numbers, names and technical terms.
5. **Weak non-English support** — Granola desktop without Polish; Otter with six languages; Google Meet notes with eight; speaker labels English-only in Notion.
6. **Data use and retention** — training by default (alleged against Granola), unclear retention (Claude Meetings publishes none), meeting content mixing with chat memory (ChatGPT).
7. **Pricing and limits** — subscriptions on top of hardware (Plaud), AI credits (Fireflies, Notion), 30-day history (Granola Basic), minute caps (Otter).
8. **Vendor risk** — Limitless users lost recording after the Meta acquisition, and service ended in the EU and UK.

### (d) Structural weaknesses

**Cloud products, against an on-device encrypted product**
- Audio and transcripts leave the device. Vendors then have to argue about training defaults, sub-processors, retention and residency; three vendors are in US court over it (Otter, Fireflies, Granola).
- Most delete the audio to reduce liability, which removes the user's ability to check the notes.
- Excluded where rules are strict: Claude Meetings itself is unavailable to ZDR, HIPAA-ready and CMEK organizations.
- Language coverage follows the transcription provider's roadmap (Granola says so in its docs), so Polish waits.
- Per-seat subscription cost; no offline use; dependency on the vendor surviving (Limitless).
- Team-first design: Claude Meetings has nothing for a single user on Pro or Max.

**An on-device product, against cloud products**
- Model quality: local LLMs that fit a laptop write weaker summaries and extract action items less reliably than frontier cloud models; cloud ASR vendors also update continuously. This is the main risk, and "better than Claude" must be measured on notes quality, not assumed.
- Speed, memory and battery: live transcription + diarization + an LLM compete with the video call itself for resources; older or 8–16 GB Macs suffer.
- Speaker names: cloud bots get names from the meeting platform for free; a local app has only audio (plus calendar attendees and, possibly, on-screen cues).
- No mobile, no in-person capture away from the Mac, no cross-device sync without building encrypted sync.
- Sharing and collaboration: no shared pages, recap emails or team workspaces by default.
- Integrations and agent hand-off: Anthropic's planned edge (Parka → Cowork / Claude Code tasks; Meetings → docs and whiteboards during the call) needs the cloud assistant.
- Model downloads of several GB and first-run setup.
- Local-only does **not** remove the consent duty: the user is still recording other people. The Granola suit targets bot-less capture.

### (e) Opportunities for a single-user, local-first Mac app

Against **Claude** (what ships is a Meet-only team bot; the Mac recorder is a leak):
1. **Serve the individual now.** Claude Meetings excludes Free/Pro/Max users and anything outside Google Meet. A local recorder works in Zoom, Teams, Slack huddles, phone calls on the Mac and in person, for one person, with no admin.
2. **Nothing leaves the Mac, provably.** Claude Meetings publishes no retention period, no deletion procedure and no language list, and is cloud by design; Parka's hosts indicate cloud speech-to-text. "Audio, transcript and notes stay on this Mac, encrypted, and work offline" is a claim Anthropic cannot make.
3. **Keep the audio (encrypted) so every note is checkable.** Claude Meetings and ChatGPT Record discard audio. Click a sentence in the notes, hear the source. This answers the "cannot verify" complaint and is only cheap for a local product.
4. **Polish and mixed Polish/English as a measured, published strength.** Anthropic lists no Polish for dictation and states no languages for Meetings. Publish WER and note-quality results on real Polish and code-switched meetings; nobody else does.
5. **Do not compete on in-call agent work.** Building docs and whiteboards during the call and routing tasks to agents is Anthropic's ground. Instead, be the best *source*: export Markdown and offer a local MCP server so the user's own Claude (or any assistant) can read meetings when the user chooses. That turns Claude from a competitor into a consumer.

Against **Granola**:
6. **Polish on the desktop.** Granola's docs: Polish is mobile-only. This is the single clearest product gap for a Polish user.
7. **Real speaker names everywhere**, not "Me/Them" outside Meet/Zoom/Teams: local diarization on the system channel, names proposed from calendar attendees, and remembered voices stored only on the device (opt-in; voiceprints are legally sensitive — see the Fireflies BIPA case — so local-only storage is itself a selling point).
8. **Reliability as a feature.** The sharpest Granola complaint is silent capture failure. Show an unmistakable recording state, self-test the system-audio path before the meeting, keep a crash-safe spool, and warn the moment no audio arrives.
9. **Keep the hybrid notepad.** It is what users love about Granola; a local product should match it (typed notes + transcript → enhanced notes, templates), not replace it with a summary.
10. **Consent built in, on by default.** Granola's notice features are optional and it is being sued. Offer a one-click consent line to paste in the chat, a visible recording indicator and a per-meeting record of how consent was given. This is cheap and it is a differentiator with EU users.
11. **Price and ownership.** No per-seat subscription for local processing, unlimited history, plain export. Meetily's and Anarlog's star counts show demand; neither claims encryption at rest, and both gate or lack speaker naming — encrypted storage plus speaker names is open ground among local tools.

Risks to plan for (INFERENCE):
- Anthropic ships Parka for individuals with cloud transcription and agent hand-off. Our answer is items 2–4 and 7, which do not depend on Anthropic staying away.
- Notes quality from a local LLM is the place we can lose. Decide the comparison method early (same real Polish and Polish/English meetings, blind rating against Granola and a frontier-model summary).
- Apple adds system-audio meeting capture to Notes. Not announced as of today; Apple's transcription and Apple Intelligence language lists still omit Polish.

---

## Open items I could not settle

- Claude Meetings: languages (Polish), speaker labels in the transcript, retention and deletion, training statement for meeting data, real user reactions (too new).
- Parka: whether it ships, when, for which plans, and where transcription runs.
- ChatGPT Record: current plans, duration cap, languages and speaker labels from the primary page (403).
- Notion, Zoom, Plaud, Circleback, Shadow, Alter: Polish on the official language lists.
- Any independent Polish or Polish/English accuracy benchmark for meeting tools.
- Direct Reddit, X and G2 evidence (search returned review articles, not the threads).
