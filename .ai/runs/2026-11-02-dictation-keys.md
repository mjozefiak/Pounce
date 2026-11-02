# Execution plan: Dictation, step 3.1 move the key logic to PouncePersistence

Source doc: .ai/specs/2026-11-01-voice-dictation.md
Branch: feat/dictation-keys (base: feat/dictation-cleanup, stacked on #17)

## Goal

Move `KeyStore`/`HistoryOpener` logic from `ClipboardPlugin` into `PouncePersistence` as `MasterKeyStore(service:)`
and `EncryptedDatabaseOpener`, so the dictation history can use the same code (plugins must not import each
other). Behaviour for the clipboard stays byte for byte identical.

## Non-goals

- The dictation history itself (steps 3.2 to 3.4, next PR). No `PounceKit` change.

## Risks

- This touches the protected clipboard key scheme (`BACKWARD_COMPATIBILITY.md` §2): same service, account,
  HKDF `info` strings and archive naming. A fixture database written by the code before the move is opened
  by the code after it.
- Rollback: revert this one PR.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 3: History

- [x] 3.1 MasterKeyStore + EncryptedDatabaseOpener, ClipboardPlugin on top of them
