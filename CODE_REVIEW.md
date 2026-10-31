# Code review checklist

Repository-specific review rules for Pounce. `om-code-review` (and therefore `om-auto-review-pr`) applies this file on top of its built-in checklist. Humans use it the same way. The source of truth for behaviour is the MVP spec, `.ai/specs/2026-10-31-pounce-launcher-mvp.md`; protected contracts are listed in `BACKWARD_COMPATIBILITY.md`.

## Review priorities

1. **Correctness and data safety.** Nothing that can lose or leak clipboard history, corrupt a database or snapshot, or silently drop a TCC permission.
2. **Privacy and security.** Clipboard data is the most sensitive thing Pounce touches.
3. **Contracts.** Plugin API, on-disk formats, settings keys and signing identity (see `BACKWARD_COMPATIBILITY.md`).
4. **Architecture.** The plugin boundaries below.
5. **Performance budgets** from the spec: panel open < 50 ms, app query < 5 ms, file query p95 < 30 ms on 1 M entries, idle memory < 150 MB.
6. **Native feel and accessibility.**
7. Style. `swift format lint --strict` owns formatting; do not raise formatting findings it would not.

## 1. Plugin architecture

Every feature is an internal, compile-time plugin. Check:

- [ ] **A new feature is a new SwiftPM target** under `Sources/<Feature>/` with a matching `Tests/<Feature>Tests/` target, plus **one registration line** in the single plugin registration list in `PounceApp`. A feature implemented inside `PounceApp` or `PounceCore` is a **major** finding.
- [ ] **No feature-specific logic in core.** `PounceCore` holds only shared, source-agnostic code: normalisation, matching, ranking, the plugin API. A `switch` on a concrete source, a feature flag for one plugin, or a type that only one plugin uses, added to core, is a **major** finding. Extending the plugin API for a new capability is fine when it is generic and follows `BACKWARD_COMPATIBILITY.md`.
- [ ] **Plugins depend only on the core / plugin API target** (plus shared infrastructure such as `Persistence` and approved third-party packages), **never on each other**. Check the `dependencies:` of each target in `Package.swift`; a plugin-to-plugin dependency is a **blocker**.
- [ ] **The panel never knows concrete sources.** `PounceApp` UI code talks to `SearchSource` / `ResultAction` / `Candidate`, not to `AppIndex`, `FileIndex` or `Clipboard` types (outside the registration list and plugin-specific settings panes).
- [ ] **Failure isolation.** A plugin that throws, times out, crashes its task or returns nothing must not break search for the other plugins: the aggregator runs sources independently, catches and logs per source, applies a per-source deadline, and still renders the other sections. A code path where one source's error aborts the whole query is a **major** finding.
- [ ] **Cancellation.** Each keystroke cancels the previous query `Task`; sources check `Task.isCancelled` / `try Task.checkCancellation()` in long loops and do not keep working on stale queries.
- [ ] **No runtime loading** of code (bundles, dylibs, `dlopen`, scripts, downloaded plugins). Any of these is a **blocker**.
- [ ] **Item keys** follow the `<source>:<id>` scheme (`app:<bundleID>`, `file:<path>`, `clip:<id>`) and a new plugin picks a new, unique prefix.

## 2. Swift 6 strict concurrency

- [ ] Targets build in Swift 6 language mode with complete strict concurrency; no target downgrades the language mode or disables checking to make a warning go away.
- [ ] **All UI is `@MainActor`**: AppKit and SwiftUI types, `NSPanel` / `NSStatusItem` controllers, view models. No AppKit call from a background context.
- [ ] **No blocking work on the main actor.** Scanning, hashing clipboard content, icon decoding, database and snapshot I/O run off the main actor (the spec's `PasteboardWatcher` only compares `changeCount` on main; reads and hashing happen in the background).
- [ ] **Shared mutable state is isolated** by an actor or confined to `@MainActor`. Types crossing isolation boundaries are `Sendable` (value types, immutable final classes, or actors).
- [ ] **No `@unchecked Sendable`, `nonisolated(unsafe)` or `@preconcurrency import` without a justification comment** next to it that explains which lock or invariant makes it safe. Missing justification is a **major** finding.
- [ ] No `DispatchQueue` / semaphore patterns that block a Swift concurrency thread (`semaphore.wait()` inside `async` code, `DispatchQueue.main.sync` from an actor).
- [ ] Actor reentrancy: state read before an `await` is re-validated after it when it matters (for example, snapshot writes and retention jobs).
- [ ] Long-lived `Task`s (watchers, timers, retention) have an owner that cancels them, and capture `self` weakly where a cycle would otherwise form.

## 3. Native macOS feel (Human Interface Guidelines)

For any UI change:

- [ ] **System materials and vibrancy** (`NSVisualEffectView` / SwiftUI `Material`) for the panel background; no hard-coded opaque backgrounds that break light/dark mode.
- [ ] **SF Symbols** for icons, with semantic names; no bundled bitmap icons where a symbol exists (app and file icons from the system are fine).
- [ ] **System fonts and text styles** (`.body`, `.headline`, `NSFont.systemFont`, Dynamic Type equivalents); no hard-coded font families.
- [ ] **Light and dark mode** and the **user's accent colour**: semantic colours only (`.primary`, `.secondary`, `NSColor.controlAccentColor`, `labelColor`, …); no hard-coded hex colours for UI chrome. Screenshots in both modes are part of QA evidence.
- [ ] **Keyboard first.** Everything reachable without a mouse: arrow keys, Return, ⌘Return, Esc, ⌘1–⌘5 in clipboard mode, ⌘⌫ to delete. The footer shows the actions available for the selected row. Focus lands in the search field when the panel opens.
- [ ] **VoiceOver.** Rows expose a label with title, kind and path / source app; buttons and toggles have accessibility labels; the selected row is announced.
- [ ] **Reduce Motion** disables or replaces animations; **Reduce Transparency** swaps materials for solid, contrasting backgrounds; **Increase Contrast** keeps text legible.
- [ ] Panel behaviour matches the spec: non-activating `NSPanel`, floating level, joins all Spaces, hides on resign key and on Esc.
- [ ] Every UI state in the spec is handled: indexing in progress, no results, clipboard access denied, paste disabled (no Accessibility), recording paused, Keychain unavailable. A missing state is a **major** finding.
- [ ] User-facing strings are localisable (`String(localized:)` / `LocalizedStringKey`), not concatenated.

## 4. Privacy and security (clipboard data)

- [ ] **Encryption at rest.** Clipboard history lives only in `clipboard.sqlite` encrypted with SQLCipher (or the R3 fallback: AES-GCM column encryption chosen in spike 0.4). Blobs > 1 MB are AES-GCM encrypted files with random names. Any new plaintext copy of clipboard data on disk (cache, temp file, export, crash dump) is a **blocker**.
- [ ] **Key handling.** The master key is 32 random bytes in the login Keychain (`kSecClassGenericPassword`, `service = app.pounce.clipboard`); sub-keys are derived with HKDF-SHA256 (`sqlcipher`, `blob`, `blob-name`). Keys never appear in logs, `UserDefaults`, files, test fixtures or error messages.
- [ ] **Keychain errors are distinguished.** Only `errSecItemNotFound` with an existing database may archive and reset; `errSecInteractionNotAllowed` and user denial disable history and retry later, never delete anything. Each path has a unit test against a Keychain mock.
- [ ] **No logging of clipboard contents**, previews, file paths from the clipboard, or query text at any log level (`os.Logger` with `privacy: .private` at most for identifiers; never `print`). This applies to tests' failure messages that could end up in CI logs too.
- [ ] **Capture filter.** Concealed / transient / auto-generated pasteboard types and ignored apps (Passwords, Keychain Access, 1Password, Bitwarden by default) are never stored. Size limits (20 MB per entry) are enforced. Pounce's own writes are not re-captured.
- [ ] **Deletion is real.** Deleting an entry, retention, and "Clear history" remove rows *and* blob files; the orphan sweep exists. Retention also cleans `clip:*` keys in `ranking.sqlite`.
- [ ] **File permissions** `0600` for everything under `~/Library/Application Support/Pounce/`.
- [ ] **TCC permissions** (Accessibility, Full Disk Access, pasteboard access): checked with preflight APIs (`CGPreflightPostEventAccess`, `NSPasteboard.accessBehavior`, a protected-path read for FDA) before use; a missing permission degrades gracefully (copy instead of paste, skip protected folders) with a visible banner, never a crash or a silent failure; no flood of TCC prompts (protected folders are skipped by default without FDA).
- [ ] No network access anywhere in the app. A new network call is a **blocker** unless a spec explicitly introduces it.
- [ ] No secrets, certificates or `.p12` files committed; signing material stays in GitHub secrets.

## 5. Tests

- [ ] **Every new or changed `SearchSource` ships with unit tests** covering: matching tiers and ordering, empty query, no results, cancellation, and the source's failure path (it must not throw past the aggregator).
- [ ] **Every new or changed `ResultAction` ships with unit tests** for each key binding it handles and for its degraded path (missing permission, target gone).
- [ ] Bug fixes include a regression test that fails before the fix.
- [ ] Database changes include a migration test from the previous schema with data; snapshot format changes include a test that an older `schema_version` triggers a full rescan, never an error.
- [ ] Tests do not depend on the real home directory, the real Keychain, the real pasteboard or TCC grants; use temp directories, `NSPasteboard(name:)`, Keychain mocks and injected clocks.
- [ ] Tests that need Accessibility / Full Disk Access, UI tests and benchmarks are not added to the CI `swift test` run; they are local/manual and their results are in the PR body.

## 6. Performance

- [ ] Hot paths (keystroke → results) allocate little, do not hit the disk, and do not hop to the main actor more than once per query.
- [ ] Changes that could affect a spec budget include a measurement (local log or benchmark) in the PR body.
- [ ] Large lists are virtualised; icons and previews load lazily off the main actor.

## 7. Build, packaging and release

- [ ] `Package.swift` changes: new dependencies are justified, license-compatible (MIT/BSD/Apache), pinned through `Package.resolved`, and SQLCipher/GRDB choices match `docs/decisions/0001-sqlite.md`.
- [ ] Bundle identifier, `LSUIElement`, minimum system version and the signing identity are not changed without following `BACKWARD_COMPATIBILITY.md`.
- [ ] Workflows do not print secrets and use the temporary-keychain import for the signing certificate.

## Validation gate

`swift build`, `swift test`, `swift format lint --strict -r Sources Tests`, in that order. Until Phase 0 adds `Package.swift` the gate cannot run; docs-only PRs are exempt and say so in the PR body. After Phase 0, a PR touching Swift code without a green gate is a **blocker**.

## Severity guidance

| Severity | Use for |
|---|---|
| **Blocker** | Plaintext or logged clipboard data, key leakage, data loss, a destructive migration, runtime code loading, a plugin depending on another plugin, a broken protected contract without the `BACKWARD_COMPATIBILITY.md` path, a red validation gate. |
| **Major** | Feature logic in core, one plugin able to break search for others, unjustified `@unchecked Sendable`, blocking work on the main actor, a missing UI state or permission-degraded path, missing tests for a new `SearchSource` / `ResultAction`, a spec budget regression. |
| **Minor** | HIG deviations (hard-coded colour or font, missing SF Symbol, missing VoiceOver label), missing Reduce Motion / Transparency handling on a non-critical view, naming, small duplication. |
| **Nit** | Optional suggestions. Never block on a nit. |
