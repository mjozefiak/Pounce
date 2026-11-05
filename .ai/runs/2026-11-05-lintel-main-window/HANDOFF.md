# Handoff — 2026-11-05-lintel-main-window

**Last updated:** 2026-11-05
**Branch:** feat/lintel-main-window
**PR:** https://github.com/mjozefiak/Pounce/pull/52
**Current phase/step:** all Tasks rows done
**Last commit:** 0ac3d53 — no test can show the real recording HUD or hang (step 6.3c-fix-c)

## What just happened
- Every step of spec A except 6.2 is implemented; the final gate (build, release build, full tests, format lint, TSan on PluginHost/Files/Clipboard/Dictation/Meetings) is green.
- Release-gate commits are 6.3a (9fce98e), 6.3b (cbd3376), 6.3c (5cfd00f): merging them enables the new window for release users; the owner may cut them. Three independent fix commits follow them (7580666, 8cdf2c9, 0ac3d53).

## Next concrete action
- Step 6.2 (Ctrl-X confirmation in the launcher) as its own PR from a fresh branch off main, depending only on step 1.1 (not part of this PR).

## Blockers / open questions
- Owner decisions listed in the PR body (feature descriptions field, Erase Data in panes, custom model folder in ModelUsage, Files banner text, Polish declension of Lintel).

## Environment caveats
- Dev runtime runnable: yes (debug app with --qa args); screen capture needs an unlocked display.
- Database/migration state: clean

## Worktree
- Path: /Users/mjozefiak/DeveloperTools/Pounce/.ai/tmp/lintel-main-window
- Created this run: yes (by the invoking session, per owner instruction)
