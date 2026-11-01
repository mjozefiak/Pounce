# Code signing

Pounce release builds are signed with a stable, self-signed certificate named **"Pounce Release"**
instead of ad-hoc signing. macOS ties Accessibility, Full Disk Access and Keychain access to an app's
*designated requirement*. With ad-hoc signing that requirement is the binary's hash, so every update
would look like a new app and users would lose their grants. With a stable certificate the requirement
is

```
designated => identifier "app.pounce.Pounce" and certificate leaf = H"<certificate SHA-1>"
```

(the certificate is self-signed, so its leaf is also its root), and it stays the same across releases (spec risk R1, `BACKWARD_COMPATIBILITY.md` section 4).

The certificate is not from Apple, so Gatekeeper still blocks the first launch; the release notes
explain "Open Anyway". The app is not notarized.

## Where the identity lives

- The certificate and private key exist only as the repository secrets `SIGNING_P12` (base64 of a
  `.p12`) and `SIGNING_P12_PASSWORD`, plus the owner's login keychain where it was created.
- Nothing secret is committed. `Resources/designated-requirement.txt` holds the expected
  designated requirement, which contains only the certificate's public SHA-1. It is not bundled
  into the app; CI compares every signed build against it.

## How CI signs

`.github/workflows/release.yml` (job `build`):

1. Creates a temporary keychain with a random password, imports the `.p12` with access for
   `/usr/bin/codesign`, sets the key partition list so `codesign` never prompts, and adds the keychain
   to the search list. Only this step receives `SIGNING_P12` and `SIGNING_P12_PASSWORD`; the decoded
   `.p12` is deleted even when the import fails, and the other steps (third-party actions, tests and
   build scripts) see only a `HAS_SIGNING_SECRETS` flag and the temporary keychain.
2. Probes `codesign` with the identity. The certificate is self-signed and therefore untrusted; if a
   runner image refuses to sign with it, the workflow trusts it in that ephemeral runner's System
   keychain only.
3. Runs `scripts/make-dmg.sh` with `SIGN_IDENTITY="Pounce Release"` and `SIGN_KEYCHAIN`. The embedded
   `SQLCipher.framework` is signed first, then the app with the hardened runtime and
   `Resources/Pounce.entitlements`, then the DMG.
4. Checks that the designated requirement names the identifier and the certificate hash (not a cdhash),
   matches `Resources/designated-requirement.txt`, and is identical after a second, independent build.
5. Uploads `Pounce.dmg`, its SHA-256 and the designated requirement as the `Pounce-dmg` artifact, then
   deletes the temporary keychain. Only a `v*` tag runs the `publish` job that creates a GitHub Release.

Pull requests from forks get no secrets; their DMG is signed ad-hoc and the requirement checks are
skipped. A tag build without the secrets fails.

### Library validation

The hardened runtime normally only loads frameworks signed with the app's Apple Team ID. A
self-signed certificate has no Team ID, so `Resources/Pounce.entitlements` sets
`com.apple.security.cs.disable-library-validation` to let the app load its own embedded
`SQLCipher.framework`. The rest of the hardened runtime stays on. Entitlements are not part of the
designated requirement, so this does not affect TCC grants.

## Local builds

`scripts/make-app.sh` and `scripts/make-dmg.sh` sign ad-hoc unless `SIGN_IDENTITY` is set. **Do not
sign with "Pounce Release" on a developer Mac**: the key's partition list in the login keychain is not
set, so `codesign` opens a keychain-access dialog and waits. Local and QA builds are always ad-hoc,
which also means a locally built app does not share TCC grants with an installed release.

## Regenerating the certificate

`scripts/make-signing-cert.sh` creates the certificate (RSA 3072, code-signing EKU, 20 years) with
OpenSSL 3, imports it into the login keychain, and with `--upload-secrets` stores `SIGNING_P12` and
`SIGNING_P12_PASSWORD` through `gh secret set`. The key and password stay in a temporary directory
that is deleted on exit; the script refuses to run if a "Pounce Release" certificate already exists.

> **Warning: regenerating the certificate is a breaking change for every user.** A new certificate
> changes the designated requirement. On the next update every user silently loses Accessibility and
> Full Disk Access grants, and the clipboard key in the Keychain (`app.pounce.clipboard`) becomes
> unreadable to the new build. Only do it when the old key is lost or compromised, and then follow
> `BACKWARD_COMPATIBILITY.md` section 4: an ADR, release notes telling users to re-grant permissions,
> and a plan for the clipboard key. After regenerating, update `Resources/designated-requirement.txt`
> in the same PR.
