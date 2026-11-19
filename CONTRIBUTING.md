# Contributing to Lintel

Thanks for helping. Lintel is a native macOS launcher (app search, file search, clipboard history,
dictation, meetings, notes, window management). It is MIT-licensed.

Many PRs in this repository are produced by coding agents that follow [AGENTS.md](AGENTS.md).
Human contributors follow the same rules.

## Reporting bugs and proposing features

Use the issue forms: [new issue](https://github.com/mjozefiak/lintel/issues/new/choose). Do not paste
clipboard contents, transcripts, notes or other private text into an issue or a log.
For vulnerabilities, do not open a public issue; see [SECURITY.md](SECURITY.md).

A new feature needs a spec first. Open a design-only PR that adds a file to [`.ai/specs/`](.ai/specs/)
named `{YYYY-MM-DD}-{kebab-case-title}.md`. The implementation ships on its own branch and PR.
Bug fixes and small changes do not need a spec. See [AGENTS.md](AGENTS.md) (task routing) and
[SDLC.md](SDLC.md).

## Development setup

- macOS 26 or later on Apple silicon, Xcode 27 (Swift 6.4).
- Clone with submodules: `git clone --recurse-submodules https://github.com/mjozefiak/lintel.git`
- Run once: `swift package resolve --disable-keychain` (downloads the SQLCipher binary).
- `scripts/make-app.sh` builds `dist/Lintel.app`, signed ad-hoc. An ad-hoc build gets a new signature on
  every rebuild, so macOS asks for its permissions again each time. See [docs/signing.md](docs/signing.md).
- To run the app against fake data, see [docs/qa.md](docs/qa.md).

## Validation gate

Run these in order before you open a PR:

1. `swift build`
2. `swift test`
3. `swift format lint --strict -r Sources Tests`

CI runs the same commands, plus some tests under `--sanitize=thread`
([ci.yml](.github/workflows/ci.yml)). A docs-only PR says so in its body.

## Branches and pull requests

- One branch and one PR per change, based on `main`.
- Use conventional-commit style titles, for example `feat(meetings): ...`, `fix(windows): ...`,
  `docs(specs): ...`.
- Fill in the PR template. Labels follow the state machine in [SDLC.md](SDLC.md).
- Review: CI must be green. A UI change needs screenshots of the running app in light and dark mode
  (the QA gate in [SDLC.md](SDLC.md)). A PR labeled `needs-qa` does not merge without `qa-approved`.

## Rules to know

The full list is in [AGENTS.md](AGENTS.md) and [CODE_REVIEW.md](CODE_REVIEW.md). In short:

- Every feature is a compile-time plugin in its own SwiftPM target. It is registered in one place,
  `Sources/LintelApp/PluginRegistry.swift`. There is no runtime loading of code.
- Dependencies flow one way. Plugins never import each other or the app target.
- Plugin code never traps: no `fatalError`, `try!` or force unwrap. Report errors by throwing.
- Plugin contracts, on-disk formats and settings keys are protected. Changes are additive. See
  [BACKWARD_COMPATIBILITY.md](BACKWARD_COMPATIBILITY.md).
- Every user-visible string needs an English and a Polish value in `Resources/Localizable.xcstrings`.
- Tests use Swift Testing, in-memory ports and temporary directories, and leave nothing behind
  (no `UserDefaults` suites, no real Keychain items).
- Never log clipboard contents, dictated text, transcripts or notes.
- A new dependency needs a reason in the PR body and an MIT, BSD or Apache-compatible license.

## License

Lintel is released under the [MIT License](LICENSE). By contributing you agree that your contribution is
licensed under the same terms. There is no CLA.

## Conduct

Be kind. Participation is covered by the [Code of Conduct](CODE_OF_CONDUCT.md).
