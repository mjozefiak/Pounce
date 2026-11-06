# ⌃X delete confirmation in the launcher panel (spec A step 6.2) — run note

Run: `2026-11-05-confirm-delete` · Branch: `feat/lintel-confirm-delete` (stacked on `feat/lintel-main-window`, PR #52) · Mode: one step, its own PR (`risk-high`)
Source spec: `.ai/specs/2026-11-04-lintel-main-window.md` step 6.2, owner decision D9 · ADR: `docs/decisions/0008-main-window-and-notes-library.md` · Prototype screen: `shell-panel-confirm`

The PR targets `feat/lintel-main-window` because the contract it uses (`ResultAction.confirmation`, `ActionConfirmation`, step 1.1) exists only there; it retargets to `main` after #52 merges. No contract change.

## Tasks

| Phase | Step | Title | Exec | Status | Commit |
|-------|------|-------|------|--------|--------|
| 6 | 6.2 | Shell handles `ResultAction.confirmation` (inline "Press ⌃X again", Esc/blur/reload/selection/5 s cancel); Clipboard, Dictation and Meetings delete opt in; BC §5 and AGENTS.md | inline | done | see PR (shell, plugin opt-ins, docs commits) |

## Notes

- Meetings had its own 3 s double press in `MeetingsLibraryActions.requestDelete`; it is removed so ⌃X is not asked three times. The "… and its audio" variant of the prompt is gone with it (the shell prompt is per action, not per row).
- `--qa-confirm-action` (DEBUG only) shows the footer for screenshots without the timeout.
