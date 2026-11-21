# ADR 0012: Distribution and updates (Developer ID, notarization, a protected sign job)

- Status: **Accepted** for the signing and release workflow parts (owner decisions D1, D2 and D3 of 2026-11-19). The
  updater, the feed and Homebrew are **deferred**; they are only named here.
- Date: 2026-11-19
- Spec: `.ai/specs/2026-11-19-updates-and-open-source-hygiene.md` (Phase 3 and Step 2.3). The spec calls this ADR
  "0010"; that number was taken by `0010-dictation-context.md` and 0011 by `0011-external-providers.md`, so this is
  the next free one (checked 2026-11-19 after merging `main`).

## Context

Until now Lintel was signed ad-hoc locally and, in the release workflow, with a self-signed "Lintel Release"
certificate. That certificate cannot be notarized, so every new user meets the Gatekeeper block ("Open Anyway"), and the
workflow imported the signing key and then ran the tests and the whole build with the keychain unlocked, in a job that
pull requests from branches of this repository could reach. No release exists yet, so the identity can still be
chosen freely.

## Decision

### Identity: Developer ID, Team ID `39G44CM6GF`, no self-signed bridge

Releases are signed with a **Developer ID Application** certificate of the owner's individual Apple Developer account
(Team ID `39G44CM6GF`, public). The first signed build is Developer ID and notarized; there is no intermediate
self-signed release. A bridge would cost the users who installed it one more round of permission grants when the real
identity arrives, for no benefit, because no release exists. The bundle identifier `com.lintelapp.Lintel` stays. The
designated requirement becomes Team-ID based (`anchor apple generic` and `certificate leaf[subject.OU] = "39G44CM6GF"`):
it survives certificate renewal, which a pinned certificate hash does not. The exact text `codesign -dr -` prints for
the first signed build is recorded in `Resources/designated-requirement.txt` (Step 3.4); while the
file held a placeholder, a tag run failed on it and a manual signed run only warned and uploaded the requirement it
printed.

The Team ID lives in one committed file, `scripts/release-team-id.txt`; `scripts/verify-release-bundle.sh` reads it.

A signature with a Team ID loads the embedded `SQLCipher.framework` and `llama.framework` under library validation, so
`Resources/Lintel.entitlements` has no `com.apple.security.cs.disable-library-validation`. Ad-hoc builds (local, QA,
pull requests) have no Team ID and use `Resources/Lintel-adhoc.entitlements`, which keeps it. `scripts/select-entitlements.sh`
decides from the `TeamIdentifier` of a probe signature, not from the identity's name, and the same rule chooses
`--timestamp` (Developer ID; notarization requires Apple's secure timestamp) or `--timestamp=none` (no network).

### Notarization

The `sign` job signs the app inside-out (frameworks, then the app, hardened runtime), submits it with
`xcrun notarytool submit` (without waiting; the script then polls `notarytool info` with a bound) using an App Store Connect API key, staples the app, builds the DMG **from the stapled
app**, signs, notarizes and staples the DMG, and only then computes `Lintel.dmg.sha256`. `scripts/verify-release-bundle.sh`
then requires `codesign --verify --strict --deep`, a requirement that names the Team ID and has no `cdhash`, `spctl`
reporting "Notarized Developer ID" and a valid staple, for the app and the DMG. A rejected submission uploads
`notarytool log` as an artifact.

### Three jobs

`release.yml` is split so that the key never sits next to code that compiles or tests:

- `build` (every trigger): no secrets, no Environment. Tests, an ad-hoc app, the release notes. The app travels as a
  zip made with `ditto` (it keeps symlinks, permissions and extended attributes, which an artifact of a directory would
  lose and which the frameworks' `Versions/Current` links and the signature depend on). A tag must be on `main`.
- `sign` (`environment: release`, only for a `v*` tag push and for a manual run with `sign: true` on `main`, never for a
  pull request): checks out the repository, selects Xcode with `xcode-select`, takes **only the `.app`** from the
  artifact, imports the certificate into a temporary keychain and runs the repository's own scripts. It builds no app code (the only Swift it runs is the 40-line `scripts/ed25519.swift` key-pair check),
  runs no tests and uses no third-party action. Apple's tools and the repository's scripts are the only code that runs
  next to the key. The Environment `release` holds `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY_P8`,
  `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`, deploys only from `main` and `v*`, and has the owner as required reviewer.
- `publish` (tags only): the GitHub Release (assets: one `.dmg`, one `.dmg.sha256`, `CHANGELOG.md`) and the website
  dispatch. A second Environment, `publish`, comes with Step 2.4.

Pull requests keep a workflow-level group with `cancel-in-progress`. Releases are serialised by a **job-level** group,
`release-tags`, on `sign` and `publish` with `queue: max` (docs.github.com, workflow syntax, `jobs.<job_id>.concurrency`:
`queue` is `single` by default, which keeps one pending job and cancels the older one; `max` keeps up to 100; it cannot
be combined with `cancel-in-progress: true`). Two tags pushed together are both signed, one after the other, none
cancelled. The first step of `sign` (inside the group, before any secret is used) runs `scripts/check-release-order.sh`:
the tagged commit must be a strict descendant of the commit of the newest published release (drafts ignored,
pre-releases included, every page of the releases API read; no release yet passes), so build numbers and publication
order cannot disagree. The group is per job, not per run, so between the end of `sign` of tag A and the start of its
`publish` the queued `sign` of tag B can run and read a "newest release" that does not yet include A. `publish`
therefore runs the same check again, inside the group, right before `gh release create`: by then every earlier
`publish` has finished, so a B older than A is refused there and nothing is published for it (the spec's "a second
tag's ancestry check runs only after the first tag is published"). The check in `sign` stays, so a tag that is plainly
out of order fails before anything is notarized.

### Remaining risk

Rules and approvals bind an account, and agents act as the owner's account (spec D16, deferred until the first public
beta). Until then the owner reads the diff of `.github/`, `scripts/` and `Resources/` before approving a `release`
deployment.

A tag run executes the workflow file and the scripts **of the tagged commit**. Anyone who can push a `v*` tag can
therefore tag a commit that is not on `main` and whose `release.yml` drops the "tag on main" check or adds steps to
`sign`; that check stops mistakes, not an attacker. What stops it is outside the file: the Environment `release`
allows `v*` as a **tag** rule (a branch rule `v*` would also match a branch named, say, `v1`, and a manual run on
that branch with an edited workflow), and the owner approves a deployment only after checking that the tag's commit is on `main`
(`git merge-base --is-ancestor <tag> origin/main`). A tag ruleset that lets only the owner create `v*` tags narrows it
further. A pull request cannot reach the secrets even with an edited workflow: the rules are matched against `GITHUB_REF`,
which for a pull request is `refs/pull/<n>/merge`, so the Environment refuses the deployment before any reviewer is
asked.

## Sparkle, embedded and off (spec Steps 4.1 and 4.3)

Sparkle 2.10.1 is a dependency of `LintelApp` only, pinned exactly; it arrives as a prebuilt XCFramework.

- **What is shipped.** `scripts/make-app.sh` copies `Sparkle.framework` into `Contents/Frameworks` and removes its
  `XPCServices`. Sparkle's documentation says only sandboxed apps need the XPC services (their `Info.plist` switches
  default to off); Lintel is not sandboxed, so they would be unused code to sign and notarize.
- **Signing order.** Inside-out, without `--deep`, each with the same identity, timestamp and hardened runtime:
  `Versions/B/Autoupdate`, `Versions/B/Updater.app`, the framework, then (after the other frameworks) the app. The
  script fails when the framework has no `Versions/B/Autoupdate` or `Updater.app`, or still holds `XPCServices`, so a
  Sparkle release with a different layout cannot be signed half-way. `codesign --verify --strict --deep` passes on
  the ad-hoc build; the Developer ID and notarization result comes from the first signed run that includes it.
- **One import.** Only `Sources/LintelApp/Updates/SparkleUpdateChecker.swift` imports Sparkle (a test checks it);
  the rest of the app talks to the `UpdateChecking` port.
- **The switch.** `UpdaterStartPolicy` (pure) lets the updater start only in a release build that runs as an app
  bundle directly in `/Applications` or `~/Applications`, is signed with a Team ID, and has `SUPublicEDKey` and an
  HTTPS `SUFeedURL` in `Info.plist`. `Info.plist` carries no `SUPublicEDKey` and sets `SUEnableAutomaticChecks` to
  `false`, so no build made before the owner's key exists creates the updater, asks the user, makes a request or
  writes a Sparkle default. DEBUG and QA builds are refused first, whatever else is true.
- **Channels.** Stable releases are Sparkle's default channel; pre-releases are in the channel `beta`, offered when
  `app.updates.includeBeta` is true (`UpdateChannel`).

- **"Lintel is busy" (spec Step 4.6).** `LintelPlugin.busyReason` (`BusyReason`: `.recording`, `.processing`; default
  `nil`) is the additive contract; `PluginHost.busyReason` takes the first non-nil value over every plugin that is
  not `failed`, a switched-off one too because a meeting session can outlive the switch-off (`.recording` first), and `UpdateController` passes it to the checker as `shouldPostponeRelaunch`. Because the contract
  has no "busy ended" event, the checker reports `UpdateEvent.relaunchPostponed` and the controller polls every 5 s,
  only while a relaunch is held back, until nothing is busy; no timer exists otherwise. Meetings (recording, preparing, finishing,
  resumed processing, notes being written; not a pending microphone decision, which holds nothing and outlives its
  HUD) and Dictation report it; Notes does not, because a quit cancels its revise
  run and leaves the document as it was.

## Sparkle switched on (Step 4.5)

- `Info.plist` carries the owner's public key `SUPublicEDKey` (public by design; the private key stays in the Environment
  `release`) and `SUPromptUserOnFirstLaunch` = true. `SUEnableAutomaticChecks` is absent, which is what makes Sparkle
  ask. Checked in Sparkle's source at the tag 2.10.1: `-[SPUUpdater startUpdateCycle]` asks only while
  `SUEnableAutomaticChecks` is in neither the defaults nor `Info.plist`, and asks on the first launch when
  `SUPromptUserOnFirstLaunch` is true (otherwise on the second, `SUHasLaunchedBefore`). While the question is up nothing
  is scheduled; after the answer `resetUpdateCycle` calls `scheduleNextUpdateCheckFiringImmediately:NO`, which returns
  without a timer when `automaticallyChecksForUpdates` is false. `SUEnableSystemProfiling` stays unset, so the
  question hides the profile checkbox and answers `sendSystemProfile` false (`SUUpdatePermissionPrompt`), and
  `parameterizedFeedURL` adds no profile: the request carries only the User-Agent `Lintel/<version> Sparkle/2.10.1`.
- Until the feed exists (Step 4.7) the address answers 404: a scheduled check fails without a window
  (`SPUScheduledUpdateDriver` shows an error only for an update it showed) and "Check Now" shows Sparkle's
  "Update Error!" alert.
- `UpdateController` does not start the updater while the welcome flow is on screen (`welcomeIsPending`); closing the
  welcome window calls `welcomeFinished()`, which starts it once. Sparkle's question therefore never appears over the
  welcome screen and nothing is requested before the user answers. After a "no" only the user's own "Check Now" asks.
- Settings → General → Updates: version and build, "Check for updates automatically" and "Download and install updates
  automatically" (both in Sparkle's own defaults, no new Lintel key), "Include beta versions" (`app.updates.includeBeta`,
  applied to the allowed channels at once), "Check Now". Where the updater is off (DEBUG, outside Applications, ad-hoc)
  only the version and one line are shown. The menu has "Check for Updates…", dimmed while the updater is off or busy.

## The feed (spec Step 4.7)

- The `sign` job builds `appcast.xml` (`scripts/make-appcast.sh`, pure) and signs it; `publish` attaches it to the release
  and the site copies it to `https://lintelapp.com/appcast.xml`. At most two items: this release and the other channel's
  item carried from the previous release's feed byte for byte (a stable, or a beta only while its build is higher than
  the stable's). The previous feed must verify; a feed that is present but does not verify fails the job.
- **Key pair check.** `scripts/sparkle-sign.sh check-key` signs a probe with `SPARKLE_ED_PRIVATE_KEY` and verifies the
  signature against `SUPublicEDKey` of the built app with CryptoKit (`scripts/ed25519.swift`), because `sign_update --verify`
  takes the public key from the private key it is given and so cannot compare with `Info.plist`. It runs before the
  certificate is imported and before notarization, so a wrong secret fails in minutes, not after hours.
- **The tool.** `sign_update` comes from Sparkle's release zip, checked against the SHA-256 in `scripts/sparkle-tools.txt`
  (the checksum SwiftPM pins; a script test ties it to `Package.swift`). The job does not resolve the package graph.
- **Race.** `sign` and `publish` of two tags can interleave, so `publish` repeats the "previous release" query and stops when
  it differs from the release the feed was built on.

## Deferred

- **Step 4.8 of the spec.** The real-updater check; Sparkle's `generate_keys` and the secret are the owner's.
- **Homebrew, spec Phase 5 (D13).** The project's own tap `mjozefiak/homebrew-lintel` (casks `lintel` and `lintel@beta`),
  updated by `publish` with `HOMEBREW_TAP_TOKEN` from the Environment `publish`. The official `homebrew/cask` is a later,
  conditional step. Not built.

## Consequences

- Positive: no Gatekeeper block for new users; a requirement that survives certificate renewal; secrets reachable only by
  tags and owner-approved manual runs; the signing job has a small, auditable surface.
- Negative: US$99 per year; two notarization round trips per release; the first signed build costs the owner one round of
  permission grants (owner checklist A in the spec); queued pull-request runs.
- Reverting: signing back to a self-signed certificate would change the requirement again (`BACKWARD_COMPATIBILITY.md`
  section 4) and is not planned.
