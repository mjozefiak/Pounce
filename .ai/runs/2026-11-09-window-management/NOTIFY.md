# Notify log

- 2026-11-09 run started
- 2026-11-09 step 1.9: spec asks to check whether `PluginContext.availableCommands` (the palette) would list the numbered commands and, if so, add a hiding flag. It has no producer in the shell (default `[]`), so no flag was added; revisit when a palette exists.
- 2026-11-09 step 1.9: the spec's "12 windows restored" strings use plural variations in the catalog; unit tests (a package without the compiled catalog) can only see the key form, so they assert the numbers, not the plural word.
- 2026-11-09 step 1.10: the strip uses the single-status-item design with a pure click-to-index mapping (`StripLayout.index(atX:boxCount:)`), accessibility children on the button and the right-click menu as the VoiceOver path. The click mapping, the children and the "no room" check cannot be verified without a real menu bar; per the owner rule the fallback (one status item per box, at most nine) is a manual decision recorded in docs/qa.md (step 1.12), not taken automatically.
