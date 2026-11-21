# Code signing

Lintel releases are signed with an Apple **Developer ID Application** certificate (Team ID `39G44CM6GF`, public, kept in
`scripts/release-team-id.txt`), notarized by Apple and stapled. Design and reasons: `docs/decisions/0012-distribution-and-updates.md`.
Protected surface: `BACKWARD_COMPATIBILITY.md` section 4.

## What the designated requirement is, and why it is recorded

macOS ties Accessibility, Full Disk Access, Microphone, System Audio Recording and Keychain access to an app's *designated
requirement*. With ad-hoc signing that requirement is the binary's hash, so every build looks like a new app and the grants
are lost. A Developer ID signature gives a requirement that names the bundle identifier and the Team ID, not a certificate
hash, so it stays the same across releases and across certificate renewals:

```
identifier "com.lintelapp.Lintel" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = 39G44CM6GF
```

`Resources/designated-requirement.txt` holds the exact text `codesign -dr -` printed for the first signed build (it starts
with `designated => `). It is public information and is not bundled into the app. Every signed run must produce exactly
that requirement or the `sign` job fails (`scripts/requirement.sh compare`). The file is one requirement and nothing else:
no comment lines, because the whole file is compared. `scripts/requirement.sh shape` (run by the script tests) pins what a
recorded requirement must contain: the identifier, `anchor apple generic`, the two Developer ID fields, the Team ID of
`scripts/release-team-id.txt` and no `cdhash`.

### Changing the recorded requirement

Changing the file means changing every user's grants, so it is a breaking change (`BACKWARD_COMPATIBILITY.md` section 4).
It happens only when the Team ID or the bundle identifier changes, and needs an ADR, release notes that tell users which
permissions to grant again, and a plan for the Keychain items. It is never done to make a failing run pass. To record a
requirement (the first signed build, or an approved change):

```bash
dir="$(mktemp -d)"
gh run download <run id> -n Lintel-requirement -D "$dir"
cp "$dir/designated-requirement.txt" Resources/designated-requirement.txt
zsh scripts/tests/run.zsh                                   # the shape check must pass
```

In one pull request with the ADR and the `BACKWARD_COMPATIBILITY.md` update. If the file still holds the placeholder
(`REPLACE-WITH...`), a tag run fails in `sign` after verification and a manual signed run only warns and uploads the
requirement it printed as `Lintel-requirement`.

## Where the identity lives

- The Developer ID certificate and private key, and the App Store Connect API key used for notarization, exist only as the
  secrets of the GitHub Environment `release` and in the owner's password manager. The five secret names are
  `DEVELOPER_ID_P12` (base64 of a `.p12`), `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY_P8`, `NOTARY_KEY_ID` and
  `NOTARY_ISSUER_ID`. No signing secret exists at repository level and nothing signing-related is committed.
- The Environment deploys only from the branch `main` and from tags `v*` (a tag rule, not a branch rule) and has the owner as
  required reviewer. **Approving a `release` deployment is the owner's alone.** A tag run executes the tagged commit's own
  workflow and scripts, so before approving, the owner checks that the tag's commit is on `main` and reads the diff of
  `.github/`, `scripts/` and `Resources/` since the previous release (ADR 0012, "Remaining risk").
- **An agent never** reads, prints, creates, changes or deletes a secret, certificate, keychain item, Environment or
  repository setting; never signs with the Developer ID identity; never creates or pushes a release tag; never triggers or
  approves a run that uses the Environment `release`; never installs a build into `/Applications`; and never edits the
  recorded requirement to make a run pass.

## How CI signs

`.github/workflows/release.yml` has three jobs.

**`build`** (every trigger; no secrets, no Environment, `contents: read`):

1. A tag run takes the version from the tag (`scripts/version-from-tag.sh`) and fails when the tag is not `vX.Y.Z` or
   `vX.Y.Z-beta.N`, when the tagged commit is not on `main` (the build number is the commit count, which only grows along
   `main`), or when `CHANGELOG.md` has no section for the version. `APP_VERSION` and `APP_BUILD` are stamped into the
   copied `Info.plist` by `scripts/stamp-version.sh`; `Resources/Info.plist` stays `0.0.0` / `0`.
2. Runs the tests (under `scripts/test-with-watchdog.sh`; not on a push to `main`, which `ci.yml` tests) and builds the app
   with an **ad-hoc** signature. Outside tags it also builds an ad-hoc DMG (`Lintel-adhoc-dmg`).
3. Uploads the app as `Lintel-app` (`Lintel.app.zip`, made with `ditto -c -k --keepParent`, which keeps symlinks, permissions
   and extended attributes) and, for a tag, the release notes (`release-notes`).

**`sign`** (`environment: release`; only for a `v*` tag push and for a manual run with `sign: true` on `main`; never for a
pull request or a push to `main`). It builds no app code (the only Swift it runs is the 40-line `scripts/ed25519.swift` key-pair check), runs no tests and
uses no third-party action:

1. Checks the release order (below), before any secret is used.
2. Selects Xcode with `xcode-select`, downloads `Lintel-app` and takes only the `.app` from it.
3. Creates a temporary keychain with a random password and imports the `.p12` with access for `/usr/bin/codesign`, then sets
   the key partition list so `codesign` never prompts. Only this step receives `DEVELOPER_ID_P12` and
   `DEVELOPER_ID_P12_PASSWORD`; the decoded `.p12` is deleted even when the import fails.
4. Finds the Developer ID Application identity in the imported certificate (exactly one, belonging to the Team ID in
   `scripts/release-team-id.txt`); the name on the certificate is not written in the repository or the log.
5. `scripts/make-app.sh --sign-only` re-signs the bundle inside-out (`SQLCipher.framework`, `llama.framework`, then the app)
   with the hardened runtime, `--timestamp` and `Resources/Lintel.entitlements`.
6. `scripts/notarize.sh` uploads the app without waiting, prints the submission id at once (also to `$GITHUB_OUTPUT` and
   `notary-logs/<file>.submission-id`) and polls `notarytool info` for at most 40 minutes (upload at most 10; a manual run may raise the app wait to 240 with the `notary_wait_minutes` input) with a progress
   line every minute; still In Progress at the bound fails the step (exit status 3, naming the id: Apple's queue, start the run
   again later, a new run signs a new binary). Each `notarytool info` or `log` call is bounded too (2 minutes), ten failed
   status reads in a row fail the step, and a status other than In Progress, Accepted, Invalid or Rejected fails it at once.
   The API key is written to a temporary file that is deleted on exit, also when the job is cancelled or cut by its
   timeout. The app is stapled, `scripts/make-dmg.sh --skip-build` builds and signs the DMG from the stapled
   app, the DMG is notarized and stapled, and only then `Lintel.dmg.sha256` is computed. A rejection uploads the notary log.
7. `scripts/verify-release-bundle.sh` checks `codesign --verify --strict --deep`, a requirement that names the Team ID with
   `anchor apple generic` and no `cdhash`, `spctl` ("Notarized Developer ID") and `stapler validate`, for the app and the DMG.
   The requirement is then compared with `Resources/designated-requirement.txt`.
8. Builds and signs the update feed (spec Step 4.7). `scripts/fetch-sparkle-tools.sh` downloads Sparkle's release zip and
   extracts `sign_update` only if the zip matches the SHA-256 in `scripts/sparkle-tools.txt`. Right after the app is taken,
   `scripts/sparkle-sign.sh check-key` signs a probe with `SPARKLE_ED_PRIVATE_KEY` and verifies it against `SUPublicEDKey` in
   the built app's `Info.plist`; a mismatch fails the run before the certificate is imported. After the DMG is final, the
   DMG is signed, the previous feed (tag runs; `scripts/fetch-previous-appcast.sh`) must verify, `scripts/make-appcast.sh`
   builds the feed, and the feed is signed and verified (`scripts/release-appcast.sh`). A manual signed run does the same
   with no previous feed, then deletes the feed (version 0.0.0, validly signed with the production key: it is never
   uploaded) and prints only the item count and that verification passed; it publishes nothing.
9. Uploads `Lintel-dmg`, `Lintel-requirement` and, for a tag, `Lintel-appcast` (`appcast.xml`), and always deletes the
   temporary keychain.

**The Sparkle key.** `SPARKLE_ED_PRIVATE_KEY` (Environment `release`) is the base64 private key `generate_keys -x` exports;
its public half is `SUPublicEDKey` in `Resources/Info.plist`. It is passed through the `env:` of the two steps that use it
and from there to `sign_update --ed-key-file -` on standard input (never an argument or a file), and `sign_update`'s output
is never shown, because it quotes a malformed key. `scripts/sparkle-sign.sh` removes the variable from the environment as
soon as it has read it, so only `sign_update` receives the key (on standard input); `swift`, `plutil` and the other scripts
never see it. Only the `sign` job names it; `ReleaseWorkflowTests` pins that.

**The key cannot be rotated by this pipeline today.** `check-key` fails every release whose `SUPublicEDKey` is not the
partner of `SPARKLE_ED_PRIVATE_KEY`, and an installed app (`SURequireSignedFeed`) rejects a feed signed with any other key
than the one it ships with. So replacing the key (or losing it) is not a configuration change: apps that already carry the
old public key could no longer be updated in place, and their users would have to install a DMG by hand. Rotation would need
its own procedure, designed and tested before it is ever needed (for example a release signed with the old key that ships
the new public key, a period in which the feed is signed with both, and a change to `check-key` that allows exactly that);
it is not implemented. Keep the key backed up (owner checklist) and never regenerate it.

**`publish`** (tags only, after `sign`): creates the GitHub Release (body: install text and the changelog section; `-beta`
tags are pre-releases; assets: the DMG, its checksum, `CHANGELOG.md`, `appcast.xml`) and asks the website to rebuild, then
waits up to ten minutes for `https://lintelapp.com/appcast.xml` to equal the new feed and only warns when it does not.
Before it creates the release it checks that the feed was built on the release that is still the newest one.

Pull requests get no Environment and no secrets, and always build ad-hoc. `sign` and `publish` of all tags share the
job-level concurrency group `release-tags` (`queue: max`), so releases go one at a time and none is cancelled. Manual
`sign` runs join the same group: while one waits for Apple (up to 240 minutes with `notary_wait_minutes`, the `sign` job
may hold the macOS runner for up to 330 minutes), a tag's `sign` and `publish` queue behind it. The first
step of `sign`, and `publish` again right before it creates the release, check that the tagged commit is a strict
descendant of the newest published release's commit (`scripts/check-release-order.sh --github`); the second check closes the
window in which another tag's `sign` runs between this tag's `sign` and `publish`.

### Library validation

The hardened runtime normally only loads frameworks signed with the app's Apple Team ID. A Developer ID signature has a Team ID
and the embedded frameworks carry the same one, so `Resources/Lintel.entitlements` does **not** set
`com.apple.security.cs.disable-library-validation`. An ad-hoc signature has no Team ID, so `Resources/Lintel-adhoc.entitlements`
(local, QA and pull-request builds) keeps it. `scripts/select-entitlements.sh` chooses the file from the `TeamIdentifier` of the
signature, never from the identity's name. Entitlements are not part of the designated requirement, so this does not affect
grants.

## Local builds

`scripts/make-app.sh` and `scripts/make-dmg.sh` sign ad-hoc unless `SIGN_IDENTITY` is set. **Never sign with the Developer ID
identity on a developer Mac**: it lives only in the Environment `release`. Local and QA builds are always ad-hoc, which also
means a locally built app does not share grants with an installed release (QA builds have their own bundle identifier,
`com.lintelapp.Lintel.QA`). Agents and scripts never install into `/Applications`.

## Not built yet

The Homebrew tap is specified (`.ai/specs/2026-11-19-updates-and-open-source-hygiene.md`, Phase 5) but does not exist. The
in-app updater reads the signed feed this workflow publishes; the grants survive an update because the requirement stays the same.
