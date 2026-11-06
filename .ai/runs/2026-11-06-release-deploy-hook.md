# Release deploy hook and asset contract (landing page companion C1)

Source doc: `.ai/specs/2026-11-06-landing-page.md` (section "Companion changes", C1; the spec lives in the Lintel app repo working tree and is copied to `lintel-web/docs/specs/`).

## Goal

After a GitHub Release is published, rebuild the Lintel website (`lintel-web`, Cloudflare Pages) so its version, size and SHA-256 follow the release, and write down the release-asset contract the site depends on.

## Scope

- `.github/workflows/release.yml`: a last step in the `publish` job that POSTs to the secret `LINTEL_WEB_DEPLOY_HOOK`. Skipped when the secret is unset; a failure is logged as a warning and never fails the release.
- `BACKWARD_COMPATIBILITY.md`: a new protected surface, "Release assets" (one `*.dmg`, one `*.dmg.sha256`, tag shape).

## Non-goals

- No change to signing, the DMG build, the release notes or the tag check.
- Nothing is signed or tagged here; the hook cannot be exercised from a pull request because `publish` runs on `v*` tags only (verified locally against a stub server).
- C2 (retire the old landing) is a separate draft PR that waits for the site to be live.

## Risks

- A hook URL is a secret: it goes through `env`, is read by `curl -K -` (not on the command line), and is never echoed.
- The hook is an unauthenticated POST; an unset or wrong secret must not turn a published release red.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: C1

- [ ] 1.1 Add the deploy-hook step to the publish job
- [ ] 1.2 Write the release-asset contract into BACKWARD_COMPATIBILITY.md
- [ ] 1.3 Verify the step script against a stub server (set, unset, failing hook)
