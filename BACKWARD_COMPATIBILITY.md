# Backward compatibility

What Pounce treats as a **protected contract surface**, what counts as a breaking change to each, and the path a change must take. Review skills check every PR against this file; implementation skills warn when a change does not comply.

Pounce has no public network API and no third-party plugin ecosystem. Its contracts are the internal plugin API (every feature target depends on it), the data it keeps on the user's disk, the user's settings, and the code-signing identity that macOS uses to remember the user's permission grants. All surfaces below are **planned** (they arrive with the MVP phases in `.ai/specs/2026-10-31-pounce-launcher-mvp.md`); the rules apply from the moment each one first ships.

Any PR that changes a surface below is `risk-high` (see `SDLC.md`) and states in its body which surface it touches and which path it followed.

## 1. Plugin API (`PounceCore`)

**Surface:** the protocols and types every feature plugin compiles against: `SearchSource`, `ResultAction`, `Candidate`, `MatchResult`, `NormalizedQuery`, `SourceID`, `ActionContext`, the plugin entry/registration type, and the `<source>:<id>` item-key scheme.

The plugins are all in-tree and compiled together, so a break shows up as a compile error, not a runtime failure. The goal of this contract is to keep plugins independent and cheap to add, not to support external binaries.

**Breaking:** removing or renaming a requirement or type; changing a signature, `async`/`throws` effects, isolation (`@MainActor`, `Sendable`) or semantics (for example the ordering of match tiers, or what `limit` means); adding a protocol requirement with no default implementation; changing an existing item-key prefix.

**Required path:**

- Prefer additive changes: new requirements with a default implementation in a protocol extension, new optional fields, new types.
- When a break is unavoidable, update **every** in-tree plugin and its tests in the same PR, so `main` never holds a plugin that does not conform.
- Item-key prefixes are persisted in `ranking.sqlite`: changing one needs a data migration (section 2).
- Record the reason in the PR body; an API redesign of more than one requirement gets an ADR in `docs/decisions/` (planned).

## 2. On-disk data and migrations

Location: `~/Library/Application Support/Pounce/`, all files `0600`.

| Store | Format | Protected because |
|---|---|---|
| `clipboard.sqlite` | SQLCipher database (`clip_item`, `clip_representation`, `clip_fts`) + encrypted `blobs/` | It is the user's history and cannot be rebuilt. |
| `ranking.sqlite` | Plain SQLite (`usage_stat`, `query_association`) | Ranking is learnt over weeks; losing it is a visible regression. |
| `index.snapshot` | Versioned binary snapshot with `schema_version` | Rebuildable by rescanning, so only the "never error" rule is protected. |
| `apps.json`, `icons/` in `Caches/` | Cache | Not protected; may change freely. |

**Breaking:** dropping or renaming a table or column; changing a column's meaning or type; any migration that deletes or rewrites user rows; changing the encryption scheme, key derivation (`HKDF-SHA256` with `info` = `sqlcipher` / `blob` / `blob-name`) or the Keychain item (`service = app.pounce.clipboard`) in a way an existing install cannot open; changing the snapshot format without bumping `schema_version`.

**Required path:**

- Databases change only through GRDB `DatabaseMigrator` migrations that are **additive** (new tables, columns with defaults, indexes). Existing migrations are never edited once released.
- Every migration ships with a test that opens a database at the previous released schema, with data, and migrates it.
- A destructive change (rare) needs a staged path across releases: add the new structure and backfill, ship, then remove the old one in a later release; plus a rollback note in the PR body.
- A crypto or key change must open existing databases with the old scheme and re-encrypt, never drop. The only permitted reset is the one in the spec: key definitively missing (`errSecItemNotFound`) → archive to `clipboard.sqlite.unreadable-<date>`, keep it 30 days.
- `index.snapshot`: bump `schema_version` on any format change; an unknown or older version must trigger a full rescan, never an error or crash.
- Downgrades are not supported, but a newer database must not be corrupted by an older build: an older build that sees a newer schema disables the feature with a message instead of migrating.

## 3. User settings keys (`UserDefaults`)

**Surface:** every `UserDefaults` key and its value type and meaning: shortcuts (stored by KeyboardShortcuts), launch at login, file index roots and exclusions, retention settings, ignored apps, recording paused, and any key added later.

**Breaking:** renaming or removing a key; changing its type or encoding; changing the meaning of a stored value; changing a default in a way that changes behaviour for users who never touched the setting (for example ignoring fewer apps by default, or capturing more types).

**Required path:**

- Declare keys in one place per target (constants, not string literals at call sites) so renames are visible in review.
- To rename or re-encode: read the old key, write the new one, and delete the old one in a one-time migration on launch; keep the migration for at least one minor release; test it.
- A default that weakens privacy (captures more, retains longer, ignores fewer apps) needs explicit owner approval in the PR.

## 4. Code-signing identity, bundle identity and TCC grants

macOS ties Accessibility, Full Disk Access and Keychain access to the app's **designated requirement** (bundle identifier + signing certificate). If it changes, every user silently loses those grants on update and the clipboard key becomes unreachable.

**Surface:** bundle identifier `app.pounce.Pounce`; the stable self-signed "Pounce Release" certificate (stored as `SIGNING_P12` / `SIGNING_P12_PASSWORD` repo secrets); the designated requirement it produces; the Keychain item and its ACL; `LSUIElement`; entitlements; the DMG/app name users install.

**Breaking:** changing the bundle identifier; re-issuing or replacing the signing certificate; switching to ad-hoc signing; changing the code-signing requirement or entitlements in a way that alters the designated requirement; renaming the app bundle.

**Required path:**

- Release builds must produce an identical designated requirement across versions: verify with `codesign -dr -` on the new build against the previous release and include the output in the release PR.
- Moving to a Developer ID certificate (or any new certificate) is a one-time, deliberate break: it needs an ADR, release notes telling users to re-grant Accessibility / Full Disk Access, and a Keychain-access migration plan so clipboard history is not lost.
- Manually verify on each release that an in-place update keeps Accessibility and Keychain access (spec step 2.5).

## 5. Keyboard shortcuts and user-visible behaviour

Not a hard contract, but changes need a release note: default hotkeys (⌘Space, fallback ⌥⌘Space, ⌘⇧V), result actions (Return, ⌘Return, ⌘C, ⌘⇧C, ⌘⌫, ⌘1–⌘5), and the paste-into-previous-app behaviour. Changing a default must not override a shortcut the user has customised.

## Not protected

Internal types outside `PounceCore`'s plugin API, view layout, caches under `~/Library/Caches/Pounce/`, log messages, build scripts' internals and CI workflow structure may change freely, as long as the validation gate stays green.
