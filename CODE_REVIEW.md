# Code review checklist

Repository-specific review rules for Pounce. `om-code-review` (and therefore `om-auto-review-pr`) applies this file on top of its built-in checklist. Humans use it the same way. The source of truth for behaviour is the MVP spec, `.ai/specs/2026-10-31-pounce-launcher-mvp.md`; protected contracts are listed in `BACKWARD_COMPATIBILITY.md`.

## Review priorities

1. **Correctness and data safety.** Nothing that can lose or leak clipboard history, corrupt a database or snapshot, or silently drop a TCC permission.
2. **Privacy and security.** Clipboard data is the most sensitive thing Pounce touches.
3. **Contracts.** The `PounceKit` plugin contract, on-disk formats and `Plugins/<id>/` paths, item keys, settings keys and signing identity (see `BACKWARD_COMPATIBILITY.md`).
4. **Architecture.** The plugin boundaries below.
5. **Performance budgets** from the spec: panel open < 50 ms, app query < 5 ms, file query p95 < 30 ms on 1 M entries, idle memory < 150 MB.
6. **Native feel and accessibility.**
7. Style. `swift format lint --strict` owns formatting; do not raise formatting findings it would not.

## 1. Plugin architecture

Every feature is an internal, compile-time plugin (spec Q9, Architecture → Model pluginów). Targets: `PounceKit` (contracts only), `PounceCore` (pure logic, no I/O), `PouncePersistence` (GRDB, migrators, `UsageRepository`), the plugins `AppsPlugin` / `FilesPlugin` / `ClipboardPlugin`, and the `PounceApp` executable (composition root with `PluginRegistry` and `PluginHost`). Check:

- [ ] **A new feature is a new SwiftPM target** under `Sources/<Name>Plugin/` with a matching `Tests/<Name>PluginTests/` target, conforming to `PouncePlugin`, plus a `PounceApp` dependency on it and **one line** in `PluginRegistry.all`. A feature implemented inside `PounceApp`, `PounceKit` or `PounceCore` is a **major** finding.
- [ ] **Dependencies flow one way:** plugins → `PouncePersistence` / `PounceCore` → `PounceKit`. Check the `dependencies:` of each target in `Package.swift`. A plugin depending on another plugin or on `PounceApp`, or `PounceKit` / `PounceCore` / `PouncePersistence` depending on any plugin, is a **blocker**. A plugin taking a third-party package directly needs the justification in §7.
- [ ] **`PounceKit` holds contracts only** (protocols, value types, DI ports), no implementation. **`PounceCore` holds only shared, source-agnostic logic** without I/O: normalisation, matching, ranking (the `Ranker` gets usage stats as an argument and never reads a database). A `switch` on a concrete plugin, a feature flag for one plugin, or a type that only one plugin uses, added to `PounceKit` or `PounceCore`, is a **major** finding.
- [ ] **`PounceKit` changes are additive only** (risk R8): every new contribution or requirement has a default in a protocol extension. Anything else follows `BACKWARD_COMPATIBILITY.md` §1; without that path it is a **blocker**.
- [ ] **The shell never knows concrete plugins.** `PounceApp` code talks to `PouncePlugin` / `SearchSource` / `ResultAction` / `Candidate`, never to `AppsPlugin`, `FilesPlugin` or `ClipboardPlugin` types, except for the `PluginRegistry` list. The footer and action shortcuts are generated from `actions(for:)`.
- [ ] **Failure isolation.** An `activate()` that throws moves only that plugin to `failed` (visible in Settings → Features); its commands, actions and panel modes are not registered. `SearchCoordinator` runs sources independently in a `TaskGroup` with a per-source budget (150 ms by default): a source that throws or overruns loses only its own section and is logged. A code path where one plugin's error aborts the whole query or app start is a **major** finding.
- [ ] **No traps in plugin code** (risk R7: plugins share one process). `fatalError`, `preconditionFailure`, `try!` and force unwrapping (`!`, `as!`, implicitly unwrapped optionals) outside tests are a **major** finding; return or throw an error instead.
- [ ] **Cancellation.** Each keystroke cancels the previous query `Task`; sources check `Task.isCancelled` / `try Task.checkCancellation()` in long loops (every 10 k nodes for file search) and do not keep working on stale queries.
- [ ] **Lifecycle.** `deactivate()` is idempotent, stops watchers (a disabled clipboard plugin does not poll `NSPasteboard`) and unregisters shortcuts; data stays until `eraseData()`.
- [ ] **No runtime loading** of code (bundles, dylibs, `dlopen`, scripts, downloaded plugins). Any of these is a **blocker**.
- [ ] **Plugin data stays in its namespace:** files in `Plugins/<id>/` (0700), settings under `plugins.<id>.`, ranking keys `<plugin id>:<key>` (`apps:<bundleID>`, `files:<path>`). No foreign keys or reads across plugins' data. A new plugin picks a new, unique `PluginID`; an existing `PluginID` never changes.

## 2. Swift 6 strict concurrency

- [ ] Targets build in Swift 6 language mode (`swift-tools-version: 6.2`) with complete strict concurrency; no target downgrades the language mode or disables checking to make a warning go away. Only `PounceApp` uses `.defaultIsolation(MainActor.self)`; `PounceKit`, `PounceCore`, `PouncePersistence` and the plugins stay `nonisolated` and declare isolation explicitly.
- [ ] **All UI is `@MainActor`**: AppKit and SwiftUI types, `NSPanel` / `NSStatusItem` controllers, the `@Observable` panel state, `PluginHost`, `HotkeyService` and the `PouncePlugin` protocol. No AppKit call from a background context.
- [ ] **No blocking work on the main actor.** Scanning, hashing clipboard content, icon decoding, database and snapshot I/O run off the main actor (the spec's `PasteboardWatcher` only compares `changeCount` on main; reads and hashing happen in the background).
- [ ] **Shared mutable state is isolated** by an actor or confined to `@MainActor`. Types crossing isolation boundaries are `Sendable` (value types, immutable final classes, or actors).
- [ ] **No `@unchecked Sendable`, `nonisolated(unsafe)` or `@preconcurrency import` without a justification comment** next to it that explains which lock or invariant makes it safe. Missing justification is a **major** finding.
- [ ] No `DispatchQueue` / semaphore patterns that block a Swift concurrency thread (`semaphore.wait()` inside `async` code, `DispatchQueue.main.sync` from an actor).
- [ ] Actor reentrancy: state read before an `await` is re-validated after it when it matters (for example, snapshot writes and retention jobs).
- [ ] Long-lived `Task`s (watchers, timers, retention) have an owner that cancels them, and capture `self` weakly where a cycle would otherwise form.

## 3. Native macOS feel (Human Interface Guidelines)

For any UI change:

- [ ] **Liquid Glass panel material:** `NSGlassEffectView` (macOS 26+) is the panel's `contentView` (`cornerRadius = 16`) with the `NSHostingView` inside it. No custom backgrounds or a second glass layer inside; the row selection is a plain rounded rectangle (`NSColor.selectedContentBackgroundColor`), not glass.
- [ ] **SF Symbols** for icons, with semantic names; no bundled bitmap icons where a symbol exists (app and file icons from the system are fine).
- [ ] **System fonts via text styles only** (`.title2` field, `.body` / `.subheadline` rows, `.caption` headers and footer); no hard-coded font families or point sizes. macOS has no Dynamic Type: the app's Text Size setting (S–XL) drives `.dynamicTypeSize`, and at XL titles do not truncate.
- [ ] **Light and dark mode** and the **user's accent colour**: semantic colours only (`.primary`, `.secondary`, `NSColor.controlAccentColor`, `labelColor`, …); no hard-coded hex colours for UI chrome. Screenshots in both modes are part of QA evidence.
- [ ] **Keyboard first**, per the spec's keyboard table: ↑/↓ and ⌃P/⌃N, Return (first action; only commits text during IME composition), ⌘Return (second action), ⌘C / ⌘⇧C (copy path / file; plain text copy when the field has a selection), ⌃X to delete a clipboard entry, ⌘1–⌘5 type filter in clipboard mode, Esc / ⌘W (clear, then close), ⌘, (Settings). ⌘⌫ stays the standard text-editing shortcut in the search field. The footer shows the actions available for the selected row. Focus stays in the search field.
- [ ] **VoiceOver.** Rows expose a label with title, kind and path / source app; buttons and toggles have accessibility labels; the selected row is announced.
- [ ] **Reduce Motion** disables the 120 ms fade; **Reduce Transparency** and **Increase Contrast** are handled by the system glass material, plus a stronger selection outline (`colorSchemeContrast`); **Differentiate Without Color**: match highlights are always bold, never colour alone.
- [ ] Panel behaviour matches the spec: non-activating `NSPanel`, floating level, joins all Spaces, hides on resign key and on Esc.
- [ ] Every UI state in the spec is handled: indexing in progress, no results, clipboard access denied, paste disabled (no Accessibility), recording paused, Keychain locked or denied, feature unavailable (plugin in `failed`). A missing state is a **major** finding.
- [ ] User-facing strings are localisable (`String(localized:)` / `LocalizedStringResource` / `LocalizedStringKey`), not concatenated, and live in the String Catalog `Localizable.xcstrings` with both `en` (base, `defaultLocalization: "en"`) and `pl` translations (Q11). A new string without its `pl` entry is a **minor** finding.

## 4. Privacy and security (clipboard data)

- [ ] **Encryption at rest.** Clipboard history lives only in `Plugins/clipboard/clipboard.sqlite`, encrypted with SQLCipher (or the R3 fallback: AES-GCM column encryption chosen in spike 0.4). Blobs > 1 MB are AES-GCM encrypted files with random UUID names in `Plugins/clipboard/blobs/`. Any new plaintext copy of clipboard data on disk (cache, temp file, export, crash dump) is a **blocker**.
- [ ] **Nothing from the clipboard reaches `ranking.sqlite`** (it is not encrypted): no clipboard item ids or keys, and no query prefixes typed in clipboard mode. Clipboard frecency comes only from `clip_item.use_count` / `last_used_at`. Any clipboard-derived write to `ranking.sqlite` is a **blocker**.
- [ ] **Key handling.** The master key is 32 random bytes in the file-based login Keychain (`kSecClassGenericPassword`, `service = app.pounce.clipboard`, default ACL; not the data-protection keychain, which needs a provisioning profile). Sub-keys are derived with HKDF-SHA256, `info` = `sqlcipher` (database), `blob` (blob files) and `content-hash` (HMAC). `content_hash` is HMAC-SHA256 with the `content-hash` sub-key, never a bare SHA-256 of clipboard content. Keys never appear in logs, `UserDefaults`, files, test fixtures or error messages.
- [ ] **Keychain errors are distinguished.** Only `errSecItemNotFound` with an existing database may archive and reset; `errSecInteractionNotAllowed` and user denial disable history and retry later, never delete anything. Each path has a unit test against a Keychain mock.
- [ ] **No logging of clipboard contents**, previews, file paths or query text in the clear: `os.Logger` (`subsystem = app.pounce`, `category = <plugin id>`) with `privacy: .private` for these values; never `print`. This applies to tests' failure messages that could end up in CI logs too.
- [ ] **Capture filter.** Concealed / transient / auto-generated pasteboard types and ignored apps (Passwords, Keychain Access, 1Password, Bitwarden by default) are never stored. Size limits (20 MB per entry) are enforced. Pounce's own writes are not re-captured.
- [ ] **Deletion is real.** Deleting an entry, retention (30 days or 1000 entries), and "Clear history" remove rows *and* blob files; the daily orphan sweep exists. "Clear history" leaves an empty database and an empty `blobs/`.
- [ ] **File permissions** `0600` for every file under `~/Library/Application Support/Pounce/` and `0700` for each `Plugins/<id>/` directory.
- [ ] **TCC permissions** (Accessibility, Full Disk Access, pasteboard access): checked with preflight APIs (`CGPreflightPostEventAccess`, `NSPasteboard.accessBehavior`, a protected-path read for FDA) before use; a missing permission degrades gracefully (copy instead of paste, skip protected folders) with a visible banner, never a crash or a silent failure; no flood of TCC prompts (protected folders are skipped by default without FDA).
- [ ] No network access anywhere in the app. A new network call is a **blocker** unless a spec explicitly introduces it.
- [ ] No secrets, certificates or `.p12` files committed; signing material stays in GitHub secrets.

## 5. Tests

- [ ] **Every new or changed `SearchSource` ships with unit tests** covering: matching tiers and ordering, empty query, no results, cancellation, and the source's failure path (it must not throw past the aggregator).
- [ ] **Every new or changed `ResultAction` ships with unit tests** for each key binding it handles and for its degraded path (missing permission, target gone).
- [ ] Bug fixes include a regression test that fails before the fix.
- [ ] Database changes include a migration test from the previous schema with data; snapshot format changes include a test that an older `schema_version` triggers a full rescan, never an error.
- [ ] `FileIndex` and `PluginHost` tests also pass under `swift test --sanitize=thread`.
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
| **Blocker** | Plaintext or logged clipboard data, clipboard data in `ranking.sqlite`, key leakage, data loss, a destructive migration, runtime code loading, a dependency against the one-way target graph (plugin → plugin, plugin → `PounceApp`, shared target → plugin), a broken protected contract without the `BACKWARD_COMPATIBILITY.md` path, a red validation gate. |
| **Major** | Feature logic in `PounceKit` / `PounceCore`, one plugin able to break search for others, a trap (`fatalError`, `try!`, force unwrap) in plugin code, unjustified `@unchecked Sendable`, blocking work on the main actor, a missing UI state or permission-degraded path, missing tests for a new `SearchSource` / `ResultAction`, a spec budget regression. |
| **Minor** | HIG deviations (hard-coded colour or font, missing SF Symbol, missing VoiceOver label), missing Reduce Motion / Transparency handling on a non-critical view, naming, small duplication. |
| **Nit** | Optional suggestions. Never block on a nit. |
