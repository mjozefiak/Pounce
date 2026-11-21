# Releasing Lintel

The runbook for the owner. Only the owner tags and approves a release; agents never do either (`AGENTS.md`, "Installing
and releasing: what agents never do"). Design: `docs/decisions/0012-distribution-and-updates.md`; signing details:
`docs/signing.md`. This file describes what the repository does today.

## Not built yet

These are named in the spec (`.ai/specs/2026-11-19-updates-and-open-source-hygiene.md`) but do not exist, so a release
does not do them:

- The Homebrew tap (`mjozefiak/homebrew-lintel`).
- The site rebuild token `LINTEL_WEB_DISPATCH_TOKEN` and the Environment `publish`. `publish` still tries the dispatch, but
  without the token it prints "the website is not rebuilt" and goes on. Rebuild `lintel-web` by hand if needed.
- A recorded designated requirement. Until `Resources/designated-requirement.txt` holds a real one (spec Step 3.4), a tag
  run fails in `sign` after verification and nothing is published; a manual signed run only warns.

## Before you tag

1. `main` is green (CI and the Release workflow's `build` job on the push to `main`).
2. `CHANGELOG.md` has exactly one section `## [x.y.z] - YYYY-MM-DD` for the version, with content (for a beta,
   `## [x.y.z-beta.N] - YYYY-MM-DD`). The `build` job fails without it. Check locally with `scripts/changelog-section.sh <version>`.
3. The commit you tag is on `main` and is a strict descendant of the commit of the newest published release (drafts
   ignored, pre-releases included). The same commit cannot carry two releases.

## The tag

Only the owner creates a `v*` tag. The grammar (`scripts/version-from-tag.sh`):

- `vX.Y.Z` is a release (`v0.1.0`).
- `vX.Y.Z-beta.N` is a pre-release, N from 1 (`v0.1.0-beta.1`).
- No leading zeros. Anything else (`v0.1`, `v0.1.0-rc.1`, `0.1.0`) fails the run in its first step.

The tag is the only source of the version. `CFBundleShortVersionString` is the tag without `v`; `CFBundleVersion` is the
number of commits (`git rev-list --count HEAD`).

```
git fetch origin
git tag v0.1.0-beta.1 <commit on origin/main>
git push origin v0.1.0-beta.1
```

## What the workflow does

`.github/workflows/release.yml`, three jobs:

- `build` (every trigger, no secrets): for a tag, checks the grammar, that the commit is on `main` and that the changelog
  section exists; runs `swift test`; builds the app ad-hoc; uploads it as `Lintel-app` and the release notes as `release-notes`.
- `sign` (Environment `release`; only for a `v*` tag and for a manual run with `sign` on `main`): checks the release order
  (tags only), takes only the `.app` from `Lintel-app`, imports the Developer ID certificate into a temporary keychain,
  re-signs, notarizes and staples the app, builds the DMG from the stapled app, notarizes and staples the DMG, writes the
  checksum, verifies (`scripts/verify-release-bundle.sh`), compares the requirement with `Resources/designated-requirement.txt`,
  and deletes the keychain. It also checks the Sparkle key, signs the DMG and builds the signed `appcast.xml` (below). It uploads
  `Lintel-dmg` and `Lintel-requirement` (and, for a tag, `Lintel-appcast`).
- `publish` (tags only): checks the release order again, creates the GitHub Release (a `-beta` tag is marked pre-release; assets:
  `Lintel.dmg`, `Lintel.dmg.sha256`, `CHANGELOG.md`, `appcast.xml`; body: install text, the checksum, the changelog section),
  tries the website dispatch, then waits up to ten minutes for `https://lintelapp.com/appcast.xml` to equal the new feed.

Tag runs queue one after another (`release-tags` group) and are never cancelled.

## The update feed

Every signed run builds `appcast.xml` (what installed apps check). You will see, in the `sign` job:

1. **Check the Sparkle signing key against the app's public key** (early, before the certificate import). It signs a probe
   with the secret `SPARKLE_ED_PRIVATE_KEY` and verifies it against `SUPublicEDKey` in the app's `Info.plist`. If it fails,
   the secret is not the partner of the public key in the app (a wrong or re-generated key, or a changed `Info.plist`).
   Nothing was signed or published. Do not paste the key into the log or an issue; fix the secret in the Environment
   `release` (export the right key with `generate_keys -x`) or restore `SUPublicEDKey`, then run again. Never "fix" it by
   changing `SUPublicEDKey` after apps with the old key have shipped: they would reject every update.
2. **Fetch the previous appcast** (tags only) and **Sign the DMG and build the appcast**. The previous feed is the
   `appcast.xml` of the newest published release that has one (drafts excluded, pre-releases included): the release the site
   serves the feed from. No such release means the feed starts fresh; a release without the file is skipped. If the GitHub API
   or the download fails, the job fails (it never treats an error as "no previous feed"). A previous feed that is present but
   does not verify fails the job too: the other channel's item would otherwise vanish. The feed holds this release and the
   other channel's item (a stable, or a beta only while it is newer than the stable), kept as it was. It also fails when this
   build number is not higher than the item it replaces, or the previous feed has an item the script did not write (more than
   two items, two of one channel, a channel other than stable and `beta`): it fails closed.
3. In `publish`, before the release is created, **Check the appcast is built on the newest release**. It fails when another
   release with a feed was published while this run waited in the queue; the feed would then lack that release. Nothing is published; tag
   the next version after the newer release.
4. After the release and the website dispatch, **Wait for the site to serve the new feed** warns (it never fails) when
   `https://lintelapp.com/appcast.xml` is not the new file after ten minutes in total. Without `LINTEL_WEB_DISPATCH_TOKEN`
   (or when the dispatch fails) it first warns that the site was not asked to rebuild and the feed must be refreshed by hand,
   and still polls. The release is valid and the live feed stays at
   the previous, validly signed one. The site is another repository (`lintel-web`): redeploy it by hand.

A manual signed run does steps 1 and 2 with no previous feed (it exercises the secret and the whole pipeline) and
publishes nothing. It does **not** upload the feed: that file would be a feed for version 0.0.0 validly signed with the
production key, downloadable by anyone who can read the run. The log shows the item count and that the signature verified; to
look at a real feed, open `appcast.xml` of the first tag's release.

### "The previous feed does not verify"

The run fails in **Sign the DMG and build the appcast** with `the feed signature of .../previous/appcast.xml is missing or
does not verify`. Nothing was published (the job fails before any upload and `publish` never starts). It means the previous
release's `appcast.xml` is unsigned, damaged, or signed with another key than `SPARKLE_ED_PRIVATE_KEY`. Do not bypass it:
dropping that feed would remove the other channel's item for every installed app.

1. Check that the secret is the right key (the early key check passed, so it matches `SUPublicEDKey`) and that the asset on the
   previous release was not edited (`gh release download <tag> --pattern appcast.xml`, then
   `SPARKLE_ED_PRIVATE_KEY=... scripts/sparkle-sign.sh verify-feed appcast.xml` on a trusted machine, never in a log).
2. If the asset is damaged and the previous release's DMG is fine, the way out is manual and owner-only: rebuild that
   release's feed by hand with `scripts/make-appcast.sh` and `scripts/sparkle-sign.sh` (the same key), and replace the
   release's `appcast.xml` asset with `gh release upload <tag> appcast.xml --clobber`; then run the new tag again (a tag
   whose run failed is not reused: tag the next version).
3. If that release has no usable feed and cannot be repaired, delete only its `appcast.xml` asset
   (`gh release delete-asset <tag> appcast.xml`). The next run then builds on the newest older release that has a feed (or
   starts a fresh feed, which drops the other channel's item once); say so in the release notes.

If the key itself was lost or replaced, see "The key cannot be rotated" in `docs/signing.md`: installed apps cannot be
updated in place and users must install a DMG by hand.

## Approving the `release` deployment

The `sign` job waits for you. Before approving, check:

1. The tag's commit is on `main`: `git merge-base --is-ancestor <tag> origin/main`.
2. The version is the one you meant (the tag name and the changelog section).
3. The diff since the previous release holds nothing unexpected:
   `git diff <previous-tag>..<tag> -- .github/ scripts/ Resources/`. A tag run uses the workflow and scripts of the tagged
   commit, and the job holds the signing secrets, so read this diff yourself. For the first release there is no previous tag; read those paths as they are on the tag.

Then approve. If any check fails, reject the deployment and fix it on `main`; a tag that was pushed is not reused.

## A manual signed run (no release)

Use it to test signing or to get a DMG without publishing: Actions, "Release", Run workflow on `main`, `sign` on. Approve
the deployment after the checks above. It publishes nothing; the DMG is the `Lintel-dmg` artifact (`gh run download <run id> -n Lintel-dmg`).

Input `notary_wait_minutes` (1 to 240, default 40) is the longest wait for Apple's verdict on the app. Tag runs always use
40; the DMG wait is always 40.

### Notarization is still "In Progress"

`scripts/notarize.sh` exits 3 when the submission is still In Progress at the bound. That is Apple's queue, not the build
(a first submission of an account can take hours). The log prints the submission id; it is also in the `notary-logs`
artifact (`<file name>.submission-id`). To look at it yourself:

```
xcrun notarytool info <submission id>
```

with your own App Store Connect credentials for `notarytool` (the CI key is not on your Mac). Then start a new run, with a larger
`notary_wait_minutes` if you expect a long wait. Only a manual run takes that input; a tag run always waits 40 minutes
and cannot be given more. A new run signs a new binary, so the old submission is not reused.
Exit 1 is a rejection (the notary log is in `notary-logs`); exit 2 is a failed upload.

## After the release: install and verify

On the owner's Mac, from the GitHub Release (or the run artifact):

1. Compare the checksum: `shasum -a 256 Lintel.dmg` equals `Lintel.dmg.sha256`.
2. Quit Lintel, drag the new Lintel onto Applications (replace).
3. In a terminal: `spctl -a -vvv -t exec /Applications/Lintel.app` says "Notarized Developer ID", and
   `xcrun stapler validate /Applications/Lintel.app` passes. A file fetched with `gh` is not quarantined, so Gatekeeper alone proves nothing.
4. `codesign -dr - /Applications/Lintel.app` shows the Team ID requirement without a `cdhash`.
5. Start Lintel. Microphone, Accessibility, Screen & System Audio Recording, Full Disk Access and the Keychain "Always Allow"
   grants must all have survived. If one did not, stop and report it; do not release again until the cause is known.

The first signed build after the ad-hoc ones is the one time the grants are lost (spec, owner checklist A).

## A bad release

Publish the next version from `main` (a new commit, a new changelog section, a new tag). Never move, delete and re-push
or reuse a tag: build numbers and the order check depend on it. If a release must be deleted on GitHub, its `appcast.xml` goes with it:
redeploy `lintel-web` by hand afterwards, so the site stops pointing at the deleted DMG and serves the feed of the newest
remaining release that has one. Until that redeploy the live feed still lists the deleted release's DMG. The next release
builds its feed on the newest remaining release's feed. Apps that already updated are not rolled back.

## Beta to stable

The same commit cannot carry two releases. Add a new commit on `main` (normally the `## [x.y.z]` changelog section for the
stable version), wait for green, then tag `vX.Y.Z` on it.
