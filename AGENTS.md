# AGENTS.md

Instructions for coding agents (and humans) working in this repository.

## Project overview

Pounce is a fast, native macOS launcher with three features: app search, file search and clipboard history. It is a menu-bar agent app (`LSUIElement`) written in Swift 6 with AppKit (`NSPanel`) and SwiftUI, built with Swift Package Manager. Search uses its own in-memory filename index kept fresh with FSEvents (not Spotlight) and an fzf-style matcher with frecency ranking; clipboard history is stored encrypted (SQLCipher, key in the Keychain) and pastes into the previous app. Pounce is MIT-licensed and distributed as a DMG built by a tag-triggered GitHub Actions workflow, plus a landing page on GitHub Pages. Target: macOS 26+ on Apple silicon.

**Status: design phase.** `main` holds only the README, the license and the agent pipeline setup. The MVP spec is `.ai/specs/2026-10-31-pounce-launcher-mvp.md` (Polish prose, English identifiers; under review on branch `feat/mvp-spec` until it merges). Phase 0 of that spec scaffolds `Package.swift` on `feat/scaffold`. Everything marked **planned** below comes from the spec and does not exist yet; when you create it, follow the layout here or update this file in the same PR.

## Architecture: features are compile-time plugins

Every feature (apps, files, clipboard, and anything added later) is an **internal, compile-time plugin**:

- It lives in **its own SwiftPM target** under `Sources/<Feature>/` with its own test target under `Tests/<Feature>Tests/`.
- It conforms to the shared plugin API defined in the core target `PounceCore` (`SearchSource`, `ResultAction`, and the plugin entry type introduced in Phase 0/1).
- It is **registered in exactly one place** at build time, in the `PounceApp` executable target (planned: a single registration list, e.g. `Sources/PounceApp/PluginRegistry.swift`). Adding a feature = adding a target + one registration line.
- Plugins depend on `PounceCore` (plus shared infrastructure such as `Persistence` and vetted third-party packages), **never on each other**. The panel never knows concrete sources.
- There is **no runtime loading** of third-party code (no bundles, dylibs, scripts or extension stores). The spec's "extensions and plugins are out of MVP scope" refers to third-party extensions; the internal plugin structure above is required.

## Task routing

| When the task involves… | Read first | Key rules |
|---|---|---|
| Process, labels, QA, merging | `SDLC.md`, `.ai/agentic.config.json`, `.ai/trackers/github.md` | One `feat/` branch and one PR per change, based on `main`. Follow the label state machine and QA gate in `SDLC.md`. |
| Specs and design docs | `.ai/specs/` (MVP spec: `.ai/specs/2026-10-31-pounce-launcher-mvp.md`), `.ai/specs/research/` | File names `{YYYY-MM-DD}-{kebab-case-title}.md`. Each spec phase ships on its own `feat/` branch and PR. Spec-only PRs stay design-only. |
| Package manifest and targets (**planned**, Phase 0) | `Package.swift`, the Architecture section of the MVP spec | Swift 6 language mode with strict concurrency. Targets: `PounceApp` (executable), `PounceCore`, `AppIndex`, `FileIndex`, `Clipboard`, `Persistence`. New dependencies need a reason in the PR body and an MIT/BSD/Apache-compatible license. |
| Plugin API / ranking core (**planned**) | `Sources/PounceCore/`, `CODE_REVIEW.md` (plugin rules), `BACKWARD_COMPATIBILITY.md` | `SearchSource` / `ResultAction` / `Candidate` are a protected contract. Matching tiers: exact > prefix > word start/acronym > substring > fuzzy; frecency never promotes across tiers. No feature-specific logic in core. |
| App shell, panel, hotkeys, settings (**planned**) | `Sources/PounceApp/` | `@MainActor` for all UI. `LauncherPanel: NSPanel` is built once and shown on hotkey (< 50 ms budget). Registration of plugins happens here and only here. Settings keys are a protected contract. |
| App search plugin (**planned**, Phase 1) | `Sources/AppIndex/`, `Tests/AppIndexTests/` | Directory scan is the source of truth; `NSMetadataQuery` only supplements. Dedupe by bundle ID. Icons load off the main thread. |
| File search plugin (**planned**, Phase 3) | `Sources/FileIndex/`, `Tests/FileIndexTests/` | Filenames only, no content search. Atomic snapshot writes (temp file + `rename`). Search never waits for a scan. No TCC prompts without Full Disk Access. |
| Clipboard plugin (**planned**, Phase 2) | `Sources/Clipboard/`, `Tests/ClipboardTests/`, Data Model section of the spec | Never log clipboard contents. Skip concealed/transient types and ignored apps. Only `errSecItemNotFound` may reset the database; every other Keychain error disables history without deleting anything. |
| Persistence and migrations (**planned**) | `Sources/Persistence/`, `BACKWARD_COMPATIBILITY.md` | Two databases (`ranking.sqlite` plain, `clipboard.sqlite` SQLCipher), files `0600`. GRDB `DatabaseMigrator`, additive migrations only. SQLCipher variant chosen in spike 0.4 (`docs/decisions/0001-sqlite.md`, planned). |
| Tests (**planned**) | `Tests/<Target>Tests/` | Every new `SearchSource` / `ResultAction` ships with unit tests. CI runs `swift test` only; tests needing Accessibility, Full Disk Access, UI tests and benchmarks are local/manual with results in the PR body. |
| Build, packaging, release (**planned**, Phase 0) | `scripts/make-app.sh`, `scripts/make-dmg.sh`, `Resources/Info.plist`, `.github/workflows/ci.yml`, `.github/workflows/release.yml` | Release signs with the stable self-signed "Pounce Release" certificate so TCC grants survive updates. Never commit signing material; it lives in repo secrets (`SIGNING_P12`, `SIGNING_P12_PASSWORD`). |
| Landing page (**planned**, Phase 4) | `docs/` (GitHub Pages), `.github/workflows/pages.yml` | QA through the browser provider (`.ai/browsers/agent-browser.md`). |
| Native UI QA | `SDLC.md` (QA gate) | Build and run the app locally; attach screenshots of the running app in light and dark mode and the relevant UI states as PR evidence. |
| Decisions and measurements (**planned**) | `docs/decisions/`, `docs/perf.md` | Record architectural decisions as numbered ADRs; record performance budgets measured against the spec. |

## Validation

Validation gate, in order (also in `.ai/agentic.config.json`):

1. `swift build`
2. `swift test`
3. `swift format lint --strict -r Sources Tests`

**Until Phase 0 adds `Package.swift`, these commands fail by design.** Docs-only PRs (process docs, specs, `.ai/` config) are exempt and say so in the PR body. After Phase 0, every PR that touches Swift code or the package manifest must pass the full gate.

## Further reading

- `SDLC.md` — ticket flow, labels, QA gate, claim protocol.
- `CODE_REVIEW.md` — Pounce-specific review checklist (applied automatically by `om-code-review`).
- `BACKWARD_COMPATIBILITY.md` — protected contract surfaces and how to change them.
- `.ai/agentic.config.json` — agent pipeline configuration.
