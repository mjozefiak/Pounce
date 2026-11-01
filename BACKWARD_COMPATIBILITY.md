# Backward compatibility

What Pounce treats as a **protected contract surface**, what counts as a breaking change to each, and the path a change must take. Review skills check every PR against this file; implementation skills warn when a change does not comply.

Pounce has no public network API and no third-party plugin ecosystem. Its contracts are the internal plugin contract in `PounceKit` (every plugin target compiles against it), the data it keeps on the user's disk, the user's settings, and the code-signing identity that macOS uses to remember the user's permission grants. All surfaces below are **planned** (they arrive with the MVP phases in `.ai/specs/2026-10-31-pounce-launcher-mvp.md`); the rules apply from the moment each one first ships. The spec's risks R4 (formats, keys and paths are the hard-to-reverse contracts, fixed before v0.1) and R8 (`PounceKit` changes are additive only) are the source of the rules in sections 1 and 2.

Any PR that changes a surface below is `risk-high` (see `SDLC.md`) and states in its body which surface it touches and which path it followed.

## 1. Plugin contract (`PounceKit`)

**Surface:** the contracts-only target `PounceKit` that every plugin compiles against: `PouncePlugin` and its contributions (`searchSources`, `commands`, `panelModes`, `onboardingSteps`, `requiredPermissions`, `settingsPane()`, `activate()`, `deactivate()`, `eraseData()`), `PluginManifest`, `PluginID`, `PluginContext`, `SearchSource`, `Candidate`, `MatchResult`, `NormalizedQuery`, `SourceID`, `ItemKey`, `ResultAction`, `ActionContext`, `PanelMode`, `PluginCommand`, `OnboardingStep`, `Permission`, and the DI ports (`KeychainClient`, `PasteboardClient`, `EventPoster`, `WorkspaceClient`, `UsageRecorder`, `PermissionsReader`), and since v0.3 the `searchStatus` contribution with `SearchStatus` and `SearchStatusAction` (default: no status). Also the `PluginID` values (`apps`, `files`, `clipboard`) and the `<plugin id>:<key>` item-key format, because both are persisted.

The plugins are all in-tree and compiled together, so a break shows up as a compile error, not a runtime failure. The goal of this contract is to keep plugins independent and cheap to add (a new plugin = a new target and one line in `PluginRegistry`, with no change to `PounceKit` or `PounceCore` beyond additive ones), not to support external binaries.

**Breaking:** removing or renaming a requirement or type; changing a signature, `async`/`throws` effects, isolation (`@MainActor`, `Sendable`) or semantics (for example the ordering of match tiers, what `limit` means, or which action is first/second in `actions(for:)`); adding a protocol requirement or contribution without a default implementation; changing an existing `PluginID` or the item-key format.

**Required path:**

- Changes are **additive only** (R8): new contributions and requirements get a default in a protocol extension, new optional fields, new types.
- `PluginID` values and the `<plugin id>:<key>` format **never change after v0.1** (R4, R8): they appear in `ranking.sqlite`, in `Plugins/<id>/` paths and in `plugins.<id>.*` settings keys. Changing one is a **blocker**.
- A non-additive change is an exception to the spec, not a routine path. It needs an owner-approved amendment to the spec and an ADR in `docs/decisions/` (planned), and it must update **every** in-tree plugin and its tests in the same PR, so `main` never holds a plugin that does not conform.

## 2. On-disk data and migrations

Location: `~/Library/Application Support/Pounce/`. All files are `0600`; each plugin directory `Plugins/<id>/` is `0700`. Only `ranking.sqlite` lives at the root; plugin data lives under `Plugins/<id>/`. The two databases are separate on purpose: a clipboard key problem must never touch ranking, and nothing from the clipboard (item ids, clipboard-mode query prefixes) is ever written to the unencrypted `ranking.sqlite`.

| Store | Owner | Format | Protected because |
|---|---|---|---|
| `ranking.sqlite` | `PounceApp`, shared with plugins through `UsageRecorder`; migrator in `PouncePersistence` | Plain SQLite (`usage_stat`, `query_association`), keys `<plugin id>:<key>` | Ranking is learnt over weeks; losing it is a visible regression. |
| `Plugins/clipboard/clipboard.sqlite` + `Plugins/clipboard/blobs/` | `ClipboardPlugin` only, with its own migrator | SQLCipher database (`clip_item`, `clip_representation`, `clip_fts`) + AES-GCM encrypted blob files with random UUID names | It is the user's history and cannot be rebuilt. |
| `Plugins/files/index.snapshot` | `FilesPlugin` | Since v0.3: the magic `PNCEIDX\0`, a little-endian `UInt32` schema version (1), then an LZFSE-compressed body (complete flag, last FSEvents id, plan fingerprint, roots with their FSEvents device UUID, then every node as parent, flags, mtime, raw name and folded name). Written atomically (temp file + `rename`, mode 0600) | Rebuildable by rescanning, so only the "never error" rule is protected. |
| `Plugins/<id>/` paths | Each plugin | Directory layout | Part of R4: existing installs look for their data there. |
| `~/Library/Caches/Pounce/Plugins/apps/apps.json` and `~/Library/Caches/Pounce/icons/` | `AppsPlugin` (`apps.json`); the shell's `IconCache` (`icons/`, shared by every plugin's rows) | Cache | Not protected; may change freely. "Erase Data" removes a plugin's `Caches/Pounce/Plugins/<id>/`. |

**Breaking:** dropping or renaming a table or column; changing a column's meaning or type; any migration that deletes or rewrites user rows; moving a store or renaming a `Plugins/<id>/` path; changing the encryption scheme, the key derivation (HKDF-SHA256 from the master key with `info` = `sqlcipher` for the database, `blob` for blob files, `content-hash` for the `content_hash` HMAC) or the Keychain item (file-based login keychain, `kSecClassGenericPassword`, `service = app.pounce.clipboard`) in a way an existing install cannot open or deduplicate against; changing the snapshot format without bumping `schema_version`.

**Required path:**

- Databases change only through GRDB `DatabaseMigrator` migrations (one migrator per database owner) that are **additive** (new tables, columns with defaults, indexes). Existing migrations are never edited once released.
- Every migration ships with a test that opens a database at the previous released schema, with data, and migrates it.
- A destructive change (rare) needs a staged path across releases: add the new structure and backfill, ship, then remove the old one in a later release; plus a rollback note in the PR body.
- A crypto or key change must open existing databases with the old scheme and re-encrypt, never drop. The only permitted reset is the one in the spec: key definitively missing (`errSecItemNotFound`) with an existing database → archive to `clipboard.sqlite.unreadable-<date>`, keep it 30 days.
- `index.snapshot`: bump `schema_version` on any format change; an unknown or older version, a different FSEvents device UUID or `complete = false` must trigger a full rescan, never an error or crash.
- Downgrades are not supported, but a newer database must not be corrupted by an older build: an older build that sees a newer schema disables the feature with a message instead of migrating.
- Since v1.0, Settings → Advanced → Reset Ranking deletes every row of `usage_stat` and `query_association` (`UsageRepository.removeAllUsage()`), after the user confirms. Like Erase Data, it is an explicit user action, not a migration; the schema is unchanged.

## 3. User settings keys (`UserDefaults`)

**Surface:** every `UserDefaults` key and its value type and meaning, in the two namespaces from the spec: `app.*` (main shortcut, `app.hotkey.userDefined`, launch at login, text size, section order) and `plugins.<id>.*` (`plugins.<id>.enabled` and each plugin's settings: file index roots and exclusions, retention, ignored apps, recording paused), plus the shortcuts stored by KeyboardShortcuts and any key added later.

Keys in use since v0.1 (declared in `Sources/PounceApp/SettingsKeys.swift` and in each plugin): `app.hotkey.userDefined` (Bool), `app.hotkey.commandDefaultsApplied` ([String] of command ids whose default shortcut was applied once), `app.onboarding.shortcutCompleted` (Bool), `app.textSize` (`s`/`m`/`l`/`xl`), `app.panelLevel` (`floating`/`statusBar`, the spike 1.2 fallback), `plugins.<id>.enabled` (Bool), `plugins.apps.roots` ([String] or String), `plugins.apps.spotlight` (Bool); KeyboardShortcuts keys `KeyboardShortcuts_mainHotkey` and `KeyboardShortcuts_command_<command id with dots as underscores>`.

Keys added in v0.2 (Phase 2, clipboard): `app.onboarding.completedSteps` ([String] of plugin `OnboardingStep.id`s finished or skipped), `plugins.clipboard.paused` (Bool), `plugins.clipboard.retentionDays` (Int, default 30), `plugins.clipboard.maximumEntries` (Int, default 1000), `plugins.clipboard.ignoredApps` ([String] of bundle identifiers; missing means the default list), `plugins.clipboard.historyResetNotice` (Bool); KeyboardShortcuts key `KeyboardShortcuts_command_clipboard_history` (default ⌘⇧V). `plugins.clipboard.qaSeed` exists only in DEBUG builds and is not a contract.

Keys added in v0.3 (Phase 3, file search): `app.sectionOrder` ([String] of plugin ids, first section first; empty or missing means `manifest.order`; unknown ids are ignored), `plugins.files.roots` ([String] or String, absolute or `~/…`; missing or empty means the home folder and `/Applications`), `plugins.files.exclusions` ([String] of names, `*` patterns and `/…` or `~/…` paths, on top of the default exclusions), `plugins.files.protectedFolders` ([String] of `desktop`, `documents`, `downloads`, `icloud` added one at a time without Full Disk Access), `plugins.files.icloud` (Bool, default true: with Full Disk Access, iCloud Drive is indexed), `plugins.files.includeHidden` (Bool, default false), `plugins.files.setupCompleted` (Bool, default false: the first scan waits for it), `plugins.files.accessNoticeDismissed` (Bool, default false). `plugins.files.qaHome` exists only in DEBUG builds and is not a contract.

v1.0 (Phase 4) adds no keys. The welcome screen reads and writes the existing `app.onboarding.shortcutCompleted` (covers the welcome and shortcut pages; set when the shortcut page is finished or skipped, or the window is closed) and `app.onboarding.completedSteps` (the plugin steps), with the same meaning as before, so an install that finished onboarding never sees the welcome screen again.

**Breaking:** renaming or removing a key; moving a key to another namespace; changing its type or encoding; changing the meaning of a stored value; changing a default in a way that changes behaviour for users who never touched the setting (for example ignoring fewer apps by default, or capturing more types).

**Required path:**

- Declare keys in one place per target (constants, not string literals at call sites) so renames are visible in review.
- To rename or re-encode: read the old key, write the new one, and delete the old one in a one-time migration on launch; keep the migration for at least one minor release; test it.
- A default that weakens privacy (captures more, retains longer, ignores fewer apps) needs explicit owner approval in the PR.

## 4. Code-signing identity, bundle identity and TCC grants

macOS ties Accessibility, Full Disk Access and Keychain access to the app's **designated requirement** (bundle identifier + signing certificate). If it changes, every user silently loses those grants on update and the clipboard key becomes unreachable.

**Surface:** bundle identifier `app.pounce.Pounce`; the stable self-signed "Pounce Release" certificate (stored as `SIGNING_P12` / `SIGNING_P12_PASSWORD` repo secrets); the designated requirement it produces; the Keychain item and its default ACL (trusts the app that created it); `LSUIElement`; entitlements; the DMG/app name users install.

**Breaking:** changing the bundle identifier; re-issuing or replacing the signing certificate; switching to ad-hoc signing; changing the code-signing requirement or entitlements in a way that alters the designated requirement; renaming the app bundle.

**Required path:**

- Release builds must produce an identical designated requirement across versions: verify with `codesign -dr -` on the new build against the previous release and include the output in the release PR.
- Moving to a Developer ID certificate (or any new certificate) is a one-time, deliberate break: it needs an ADR, release notes telling users to re-grant Accessibility / Full Disk Access, and a Keychain-access migration plan so clipboard history is not lost.
- Manually verify on each release that an in-place update keeps Accessibility and Keychain access (spec step 2.5).

## 5. Keyboard shortcuts and user-visible behaviour

Not a hard contract, but changes need a release note:

- **Default hotkeys** (spec Q6, Q10): ⌘Space opens the launcher, or ⌃⌥Space when Spotlight holds ⌘Space (⌥⌘Space is never used: it opens the Finder search window); ⌘⇧V opens clipboard history. The first launch shows a shortcut recorder prefilled with the default.
- **A user-chosen shortcut always wins** (`app.hotkey.userDefined`): no automatic switch (⌃⌥Space → ⌘Space) and no new default may override a shortcut the user has recorded.
- **Result actions** (spec keyboard table): Return (first action; paste in clipboard mode), ⌘Return (second action), ⌘C / ⌘⇧C (copy path / file), ⌃X (delete a clipboard entry), ⌘1–⌘5 (clipboard type filter). ⌘⌫ stays the standard text-editing shortcut in the search field.
- **Paste into the previous app** in clipboard mode, falling back to copy-only without Accessibility or under Secure Event Input.
- **First launch** (v1.0): one welcome screen (welcome, shortcut, then each enabled plugin's steps, each skippable) replaces the separate shortcut window. **About Pounce** opens Pounce's own window with the third-party notices instead of the standard panel.

## Not protected

Internal types outside `PounceKit`, `PounceCore` internals, view layout, caches under `~/Library/Caches/Pounce/`, log messages, build scripts' internals and CI workflow structure may change freely, as long as the validation gate stays green.
