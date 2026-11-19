# Code signing

> **Status (2026-11-19).** The release workflow and the scripts now sign with **Developer ID** (Apple Team ID
> `39G44CM6GF`) and notarize; this file was corrected only where the old text had become false. The full rewrite, the
> recorded designated requirement and the removal of `scripts/make-signing-cert.sh` come with the next pull request
> (spec `.ai/specs/2026-11-19-updates-and-open-source-hygiene.md`, Step 3.4). Design: `docs/decisions/0012-distribution-and-updates.md`.

macOS ties Accessibility, Full Disk Access and Keychain access to an app's *designated requirement*. With ad-hoc
signing that requirement is the binary's hash, so every update would look like a new app and users would lose their
grants. Release builds are therefore signed with a **Developer ID Application** certificate. Its requirement names the
bundle identifier and the Team ID, not a certificate hash, so it stays the same across releases and certificate renewals:

```
designated => identifier "com.lintelapp.Lintel" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = 39G44CM6GF
```

(shape from the spec; `Resources/designated-requirement.txt` will hold the exact text `codesign -dr -` prints for the
first signed build, recorded by Step 3.4. `BACKWARD_COMPATIBILITY.md` section 4.) The build is notarized by Apple, so
Gatekeeper does not block the first launch.

There is no self-signed release identity any more. No release was ever published with one, and the owner decided not to
ship a self-signed bridge (spec D3).

## Until the requirement is recorded

`Resources/designated-requirement.txt` holds a placeholder (`REPLACE-WITH-...`) until Step 3.4. While it does:

- a **tag** run fails in the `sign` job, after verification, with a message saying so, so nothing is published;
- a **manual** signed run (Run workflow on `main` with "sign" on) only warns and uploads the requirement it printed as the
  `Lintel-requirement` artifact, which is what Step 3.4 commits.

Once the file holds a real requirement, every signed run must produce exactly that requirement or it fails.

## Where the identity lives

- The Developer ID certificate and private key, and the App Store Connect API key used for notarization, exist only as
  secrets of the GitHub Environment `release`: `DEVELOPER_ID_P12` (base64 of a `.p12`), `DEVELOPER_ID_P12_PASSWORD`,
  `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, plus the owner's password manager. The Environment deploys only
  from `main` and `v*` and has the owner as required reviewer. No signing secret is stored at repository level. The old
  repository secrets `SIGNING_P12` and `SIGNING_P12_PASSWORD` hold a dead certificate and nothing uses them.
- Nothing secret is committed. The Team ID (public) is in `scripts/release-team-id.txt`. `Resources/designated-requirement.txt`
  holds the expected requirement (public information); it is not bundled into the app.

## How CI signs

`.github/workflows/release.yml` has three jobs.

**`build`** (every trigger; no secrets, no Environment, `contents: read`):

1. A tag run takes the version from the tag (`scripts/version-from-tag.sh`) and fails when the tag is not `vX.Y.Z` or
   `vX.Y.Z-beta.N`, when the tagged commit is not on `main` (the build number is the commit count, which only grows along
   `main`), or when `CHANGELOG.md` has no section for the version. `APP_VERSION` and `APP_BUILD` are stamped into the
   copied `Info.plist` by `scripts/stamp-version.sh`; `Resources/Info.plist` stays `0.0.0` / `0`.
2. Runs the tests and builds the app with an **ad-hoc** signature (pull requests and manual runs also build an ad-hoc DMG
   and upload it as `Lintel-adhoc-dmg`).
3. Uploads the app as `Lintel-app` (`Lintel.app.zip`, made with `ditto -c -k --keepParent`, which keeps symlinks,
   permissions and extended attributes) and, for a tag, the release notes (`release-notes`).

**`sign`** (`environment: release`; only for a `v*` tag push and for a manual run with `sign: true` on `main`; never for a
pull request). It compiles nothing, runs no tests and uses no third-party action:

1. Selects Xcode with `xcode-select`, downloads `Lintel-app` and takes only the `.app` from it.
2. Creates a temporary keychain with a random password and imports the `.p12` with access for `/usr/bin/codesign`, then
   sets the key partition list so `codesign` never prompts. Only this step receives `DEVELOPER_ID_P12` and
   `DEVELOPER_ID_P12_PASSWORD`; the decoded `.p12` is deleted even when the import fails.
3. Finds the Developer ID Application identity in the imported certificate (exactly one, and it must belong to the Team ID
   in `scripts/release-team-id.txt`); the name is not written in the repository.
4. `scripts/make-app.sh --sign-only` re-signs the bundle inside-out (`SQLCipher.framework`, `llama.framework`, then the app)
   with the hardened runtime, `--timestamp` and `Resources/Lintel.entitlements`.
5. `scripts/notarize.sh` submits the app (`xcrun notarytool submit --wait`; the API key is written to a temporary file that
   is deleted on exit), the app is stapled, `scripts/make-dmg.sh --skip-build` builds and signs the DMG from the stapled
   app, the DMG is notarized and stapled, and only then `Lintel.dmg.sha256` is computed. A rejection uploads the notary log.
6. `scripts/verify-release-bundle.sh` checks `codesign --verify --strict --deep`, a requirement that names the Team ID with
   `anchor apple generic` and no `cdhash`, `spctl` ("Notarized Developer ID") and `stapler validate`, for the app and the DMG.
   The requirement is compared with `Resources/designated-requirement.txt` (see above).
7. Uploads `Lintel-dmg` (DMG and checksum) and `Lintel-requirement`, and always deletes the temporary keychain.

**`publish`** (tags only, after `sign`): creates the GitHub Release (body: install text and the changelog section; `-beta`
tags are pre-releases; assets: the DMG, its checksum, `CHANGELOG.md`) and asks the website to rebuild.

Pull requests get no Environment and no secrets, and always build ad-hoc. `sign` and `publish` of all tags share the job-level concurrency group `release-tags` (`queue: max`), so releases go one
at a time and none is cancelled; the first step of `sign` checks that the tagged commit is a strict descendant of the
newest published release's commit (`scripts/check-release-order.sh`).

### Library validation

The hardened runtime normally only loads frameworks signed with the app's Apple Team ID. A Developer ID signature has a
Team ID and the embedded frameworks carry the same one, so `Resources/Lintel.entitlements` does **not** set
`com.apple.security.cs.disable-library-validation`. An ad-hoc signature has no Team ID, so `Resources/Lintel-adhoc.entitlements`
(local, QA and pull-request builds) keeps it. `scripts/select-entitlements.sh` chooses the file from the `TeamIdentifier`
of the signature, never from the identity's name. Entitlements are not part of the designated requirement, so this does
not affect TCC grants.

## Local builds

`scripts/make-app.sh` and `scripts/make-dmg.sh` sign ad-hoc unless `SIGN_IDENTITY` is set. **Never sign with the Developer ID
identity on a developer Mac**: the release identity lives only in the Environment `release`. Local and QA builds are always
ad-hoc, which also means a locally built app does not share TCC grants with an installed release, and agents never install
into `/Applications`.

## Regenerating the certificate (obsolete)

`scripts/make-signing-cert.sh` created the old self-signed "Lintel Release" certificate. It is no longer part of the plan and
nothing calls it; Step 3.4 removes it. **Do not run it.** Replacing the Developer ID certificate keeps the requirement as long as
the Team ID stays the same; changing the Team ID is a breaking change for every user (`BACKWARD_COMPATIBILITY.md` section 4).
