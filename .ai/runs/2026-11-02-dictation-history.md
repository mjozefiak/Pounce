# Execution plan: Dictation, Phase 3 history (spec steps 3.2 to 3.4)

Source doc: .ai/specs/2026-11-01-voice-dictation.md
Branch: feat/dictation-history (base: feat/dictation-keys, stacked on #18)

## Goal

Keep finished dictations in an encrypted history (`dictation.sqlite`), browse and re-paste them from a list
mode, and let the user switch it off, limit it, clear it and erase it.

## Non-goals

- Anything in `PounceKit` (no contract change), audio storage, export, sync.

## Risks

- New persistent user data: encrypted with a key in the Keychain; text never reaches logs, `ranking.sqlite`
  or (longer than the restore delay) the pasteboard.
- Key loss: only `errSecItemNotFound` may reset the history (archive kept 30 days).
- Rollback: revert this PR; the file and the Keychain item stay on disk but nothing reads them.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 3: History

- [x] 3.2 DictationStore, migration, FTS5, retention
- [x] 3.3 List mode "Dictation History"
- [x] 3.4 Privacy settings, Clear History, Erase Data, compatibility notes
