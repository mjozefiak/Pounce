# ADR 0001: GRDB with SQLCipher through SwiftPM

- Status: accepted (spike 0.4 of the MVP spec)
- Date: 2026-10-31
- Spec: `.ai/specs/2026-10-31-pounce-launcher-mvp.md`, risk R3

## Context

Clipboard history (`Plugins/clipboard/clipboard.sqlite`) must be encrypted at rest with SQLCipher, and
the app also keeps a plain `ranking.sqlite`. GRDB supports SQLCipher, but it does not publish a
SwiftPM product for it: its README asks SwiftPM users to fork GRDB and edit `Package.swift` (the
"GRDB+SQLCipher" comments in GRDB's manifest). The variant has to be chosen before any database
exists, so the choice never forces a dependency swap or a data migration later. Open questions were
whether SQLCipher links cleanly next to the system `libsqlite3` that Foundation and Core Data load,
and whether a raw HKDF-derived key works with GRDB's `usePassphrase`.

## Decision

`Packages/GRDBCipher` is a small local package that applies GRDB's documented SQLCipher recipe from
the outside:

- `Packages/GRDBCipher/upstream` is a git submodule pinned to the unmodified GRDB.swift release tag
  `v7.11.1` (`b83108d1`). No upstream file is edited.
- `Packages/GRDBCipher/Package.swift` builds GRDB's sources from the submodule with exactly the
  recipe's changes: the `GRDBSQLCipher` shim instead of the `GRDBSQLite` system library, a dependency
  on Zetetic's official [SQLCipher.swift](https://github.com/sqlcipher/SQLCipher.swift) pinned to
  `4.20.0` (an XCFramework binary target with a checksum), and the `SQLITE_HAS_CODEC` / `SQLCipher`
  defines. GRDB's privacy manifest is excluded because a resource bundle cannot be located from a
  plain `.app`.
- `PouncePersistence` depends on this `GRDB` product. Every database goes through it: plain databases
  (`ranking.sqlite`) simply open without a key.
- Keys are passed as SQLCipher raw keys (`x'<64 hex>'` via `usePassphrase(Data)`), so the 32-byte
  HKDF-SHA256 sub-key (`info = "sqlcipher"`) is used directly without a PBKDF2 pass on top
  (`DatabaseKey`, `DatabaseFactory.openQueue`).
- SQLCipher ships as a dynamic framework. `scripts/make-app.sh` embeds it in
  `Pounce.app/Contents/Frameworks`, adds the `@executable_path/../Frameworks` rpath, and signs it
  with the app's identity before signing the app.

Licenses: GRDB is MIT, SQLCipher Community Edition is BSD-style; both are compatible with Pounce's
MIT license. SQLCipher's license requires its notice in binary distributions, so
`Resources/THIRD_PARTY_NOTICES.txt` (both notices) ships in `Pounce.app/Contents/Resources`.

## Spike results (macOS 27.0.1, Xcode 27.2, Swift 6.4.2)

| Check | Result |
|---|---|
| Builds with SwiftPM, Swift 6 language mode | yes |
| `PRAGMA cipher_version` / `cipher_provider` | `4.20.0 community` / `commoncrypto` (no OpenSSL) |
| SQLite version inside SQLCipher | 3.54.1, FTS5 available (needed for `clip_fts`) |
| Open without a key | fails with `SQLITE_NOTADB` (error 26) |
| Open with a different key | fails with `SQLITE_NOTADB` |
| Open with the HKDF-derived raw key | reads data and the FTS5 index |
| File contents | no `SQLite format 3` header, no plaintext of inserted rows |
| Plain database through the same GRDB | works, normal SQLite header |
| Core Data store (system `libsqlite3`) in the same process | works; the two libraries coexist through two-level namespaces |

The unit tests in `Tests/PouncePersistenceTests/SQLCipherSpikeTests.swift` keep these properties
under CI.

## Consequences

- The R3 fallback (system GRDB plus AES-GCM column encryption, no `clip_fts`) is not needed; the
  spec's Data Model stays as written.
- Clones need the submodule: `git clone --recurse-submodules` or `git submodule update --init`.
  CI checks out submodules (top level only; GRDB's own `SQLiteCustom` submodule is not used).
- SwiftPM downloads the SQLCipher XCFramework (about 50 MB) on first resolve. On a developer Mac,
  `swift package resolve --disable-keychain` avoids a Keychain lookup for github.com credentials
  during that download.
- Updating GRDB: move the submodule to a new tag, compare that tag's "GRDB+SQLCipher" comments and
  swift settings with `Packages/GRDBCipher/Package.swift`, and raise SQLCipher.swift to at least the
  version GRDB names. Updating SQLCipher: bump the exact version; a major SQLCipher release may need
  `PRAGMA cipher_compatibility` for existing databases, which is a data-format change under
  `BACKWARD_COMPATIBILITY.md` section 2.
- If maintaining the wrapper becomes a burden, the alternative is a fork of GRDB under the owner's
  account with the recipe applied in its own `Package.swift`; the products and module names would not
  change, so no Pounce code would.
