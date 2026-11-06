# Retire the old landing page (landing page companion C2)

Source doc: `.ai/specs/2026-11-06-landing-page.md` ("Companion changes", C2).

> **MERGE AFTER LAUNCH.** This PR stays a draft labelled `do-not-merge` until the new site (`lintel-web`, https://lintelapp.com) is live and `SITE_LIVE=1` is set in production (spec Phase 3.2). Merging earlier takes the only public page offline.

## Goal

Remove the GitHub Pages landing page that the new Next.js site replaces, and point every reference at the new place.

## Scope

- Delete `docs/index.html`, `.github/workflows/pages.yml` and `Tests/LintelAppTests/LandingPageTests.swift` (it reads `docs/index.html`).
- `AGENTS.md` "Landing page" row now points to `lintel-web`; `SDLC.md` QA note and `README.md` website link updated; the About window's Website link and `AboutInfo.websiteURL` go to https://lintelapp.com/.
- `CODE_REVIEW.md` UI-change checklist gets "update the landing replica" (the Notes window and panels in `lintel-web` copy the app's look).

## Non-goals

- No change to the new site, to release assets or the release workflow (that is C1, PR #60).
- Switching GitHub Pages off in the repository settings is an owner action after merge.

## Risks

- Earlier merge = no public page. The `do-not-merge` label and this banner guard it.
- The About window's URL changes; if lintelapp.com is not live the link 404s until it is.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: C2

- [ ] 1.1 Remove the old page, its workflow and its test
- [ ] 1.2 Repoint AGENTS.md, SDLC.md, README.md, the About URL and the UI checklist
- [ ] 1.3 Run the validation gate
