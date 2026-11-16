# DICT-3.0: TCCProtectedLocations in a shared target

Source doc: .ai/specs/backlog/2026-11-13-epic-context-aware-dictation.md (story DICT-3.0; the backlog file is not committed in this PR, it lands with PR #72)

## Goal
Behaviour-preserving refactor: `LintelApp`, `MeetingsPlugin` and others can check whether a path is TCC-protected without importing `FilesPlugin`.

## Scope
- `LintelCore` (no I/O): `PathText`, `TCCProtectedLocations` (classification: `requiresFullDiskAccess`, `homeLocations`, `fold`, `withoutDataPrefix`; paths and home are arguments).
- `LintelPersistence` (I/O): `TCCPathResolver` (`resolve`, `realPath`, `protectedIdentities`, `Resolution`).
- `FilesPlugin` uses the shared types; `ProtectedFolder` stays (it carries UI titles) and a test pins it to the shared list.
- Tests move with the code; assertions unchanged.

## Non-goals
No change in `LintelKit`, behaviour, settings keys or backlog files.

## Risks
Drift between `ProtectedFolder` and the shared list (pinned by a test); TSan on FilesPluginTests.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Move

- [ ] 1.1 Move PathText and classification to LintelCore, resolver to LintelPersistence, FilesPlugin uses them
- [ ] 1.2 Move tests, docs (AGENTS.md), full gate and TSan
