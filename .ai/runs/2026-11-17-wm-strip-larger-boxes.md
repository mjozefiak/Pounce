# Larger workspace boxes in the menu bar strip, empty workspaces dimmed

Source: owner request 2026-11-17 (research sections 3 and 4 of the window-management fixes report).

## Goal
Bigger, easier to click strip boxes; empty workspaces visibly different from occupied ones; verify that empty workspaces are drawn.

## Scope
`StripLayout` metrics (24x18, gap/padding 3 up to six boxes; 22x18, 2 from the seventh), `StripImage` (12 pt digits, radius 5, outline 1.25, dimmed empty boxes, height `min(22, thickness)`), click mapping, `StripTests`, spec addendum, `docs/windows-plugin.md`.

## Non-goals
Default workspace count 9 (v2 step 1.6), workspace names (branch `feat/window-management-v2-phase1`), the `occupied` mode, the default mode `all`.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Strip

- [x] 1.1 Metrics, image and click mapping with tests
- [x] 1.2 Spec addendum and docs
- [x] 1.3 Debug-app QA of the strip (light/dark, empty workspace)
