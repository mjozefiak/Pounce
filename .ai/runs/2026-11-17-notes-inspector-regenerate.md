# Notes inspector: Regenerate Notes in ACTIONS

Goal: a meeting note with ready notes offers "Regenerate Notes" in the inspector's Actions list, with the same
action and conditions as the meeting window (`MeetingNoteSource.actions(for:)`).

Scope: `NotesPlugin` only. The action already comes through the existing `NoteSource.actions(for:)` contract, so
`LintelKit` and `MeetingsPlugin` are untouched. Non-goals: new strings (the catalog has en+pl), QA fixtures.

## Progress

### Phase 1: Inspector action

- [x] 1.1 List the owner's source actions in the inspector (hidden where a strip already shows them)
- [x] 1.2 Tests
- [x] 1.3 Full gate (build, test, format lint)
