# lintel-app: design proposal v2 (accepted by the owner 2026-11-04)

v2 redesigns Notes after owner feedback (v1 looked amateur; reference: Orca screenshots). v1 is not kept. Default theme is now dark.

Whole-app design outside the launcher panel: main window (Notes + Settings), Models, Permissions, menu bar, Welcome, HUDs, confirmations.

- Open: `cd .ai/prototypes/lintel-app && python3 -m http.server 8765 --bind 127.0.0.1`, then `http://127.0.0.1:8765/index.html`. Query: `?theme=dark&size=1.3&lang=pl` (size 0.9 = S, 1 = M, 1.3 = XL).
- Source: owner brief of 2026-11-04 (spec: `.ai/specs/2026-11-04-lintel-main-window.md` and `.ai/specs/2026-11-04-notes-workspace.md`; ADR 0008). Contract: `.uxproof/` (stale: Pounce paths, brand pending; not regenerated), approved brand tokens from `.ai/prototypes/lintel-brand`.
- Runtime: portable HTML, native components represented, not reused. 48 screens with stable IDs `lib-*`, `set-*`, `shell-*`, `dlg-*` (list in section 5 "Coverage").
- Simulations: all data is fictional; toggles, tabs and buttons inside screens are static (only the toolbar is interactive).
- Review comments: no comment engine (the scaffold was not used); feedback goes through the owner's reply, keyed by screen ID.
- Evidence: screenshots were kept outside the repository (they show only fictional data); the prototype's section 8 lists what was and was not inspected.
- Deviations: the specs' deviation tables are applied (step 0.2): marked-later screens (`shell-menu-rec`, `shell-welcome-denied`), no Dictation Language row, Notes pane in the settings sidebar, comment shortcut Shift-Command-M. See the "Deviations applied" section of `index.html`.
