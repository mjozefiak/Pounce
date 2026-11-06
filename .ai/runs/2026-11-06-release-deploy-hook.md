# Release deploy hook and asset contract (landing page companion C1)

Source doc: `.ai/specs/2026-11-06-landing-page.md` (section "Companion changes", C1; the spec lives in the Lintel app repo working tree and is copied to `lintel-web/docs/specs/`).

## Goal

After a GitHub Release is published, rebuild the Lintel website (`lintel-web`, Cloudflare Pages) so its version, size and SHA-256 follow the release, and write down the release-asset contract the site depends on.

## Scope

- `.github/workflows/release.yml`: a last step in the `publish` job that sends a `release-published` `repository_dispatch` to `mjozefiak/lintel-web` with the secret `LINTEL_WEB_DISPATCH_TOKEN` (revised 2026-11-06: the Cloudflare Pages project is direct upload and has no deploy hook, so lintel-web's `deploy.yml` listens for the dispatch). Skipped when the secret is unset; a failure is logged as a warning and never fails the release.
- `BACKWARD_COMPATIBILITY.md`: a new protected surface, "Release assets" (one `*.dmg`, one `*.dmg.sha256`, tag shape).

## Non-goals

- No change to signing, the DMG build, the release notes or the tag check.
- Nothing is signed or tagged here; the hook cannot be exercised from a pull request because `publish` runs on `v*` tags only (verified locally against a stub server).
- C2 (retire the old landing) is a separate draft PR that waits for the site to be live.

## Risks

- The dispatch token is a secret: it goes through `env` (`GH_TOKEN`) to `gh api`, never on a command line, and is never echoed. It is a fine-grained PAT limited to `lintel-web` (Contents: read and write).
- An unset or wrong token must not turn a published release red.

## Progress

PR: #60

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: C1

- [x] 1.1 Add the deploy-hook step to the publish job — 7b5024a
- [x] 1.2 Write the release-asset contract into BACKWARD_COMPATIBILITY.md — 7b5024a
- [x] 1.3 Verify the step script against a stub server (set, unset, failing hook) — 7b5024a
- [x] 1.4 Rework the step from a deploy hook to a repository_dispatch (stub `gh`: unset, ok, failing; the token never appears in arguments)
