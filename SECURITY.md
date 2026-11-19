# Security policy

## Supported versions

Lintel has not published a tagged release yet. Until it does, only `main` receives fixes. After the first
release, only the latest release (and `main`) will.

## Reporting a vulnerability

Do not report vulnerabilities in a public issue, pull request or discussion.

Use GitHub private vulnerability reporting: open the repository's **Security** tab, choose
**Report a vulnerability**, or go to <https://github.com/mjozefiak/Pounce/security/advisories/new>.

If that form is not available, open an issue that asks for a private way to reach the maintainer. Do not
put any details of the problem in that issue.

Please include:

- what the problem is and what an attacker could do with it,
- the Lintel version (About window) and the macOS version,
- steps to reproduce, or a proof of concept,
- whether you have shared the problem with anyone else.

Do not include real clipboard contents, transcripts, notes or other private data.

## Scope

In scope: the app, its release workflow, signing and update pipeline, the encrypted stores and the
Keychain handling.

Out of scope:

- issues that need a Mac that is already compromised, or root access,
- bugs in third-party dependencies themselves, unless the way Lintel uses them makes them exploitable.

## What to expect

Lintel is maintained by one person, so replies are best effort. The goal is to acknowledge a report within
7 days. This is a goal, not a guarantee. We prefer coordinated disclosure: please give us time to ship a fix
before you publish. If you want credit, say so and you will be named in the release notes.

## Security model

- The clipboard, dictation, meetings and notes stores are encrypted with SQLCipher. Their keys live in the
  login keychain.
- Plugins are compiled into the app. Lintel does not load code at runtime (no bundles, dylibs or scripts).

More detail is in [AGENTS.md](AGENTS.md) and [CODE_REVIEW.md](CODE_REVIEW.md).
