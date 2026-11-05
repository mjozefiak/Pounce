# Lintel design conventions

Generated sections describe the code today; the manual section below is the team's rule and wins on conflict.

## Stack (generated, by hand: the web extractor does not read Swift)
SwiftUI inside AppKit windows (`NSPanel`, `NSWindow`), macOS 26, Liquid Glass (`NSGlassEffectView`, `.glassEffect`) on the launcher panel and the dictation HUD. Settings is `NSTabViewController` (toolbar style) hosting SwiftUI `Form(.grouped)` panes, 600 pt wide. The brand accent comes from `LintelBrand` (Verdigris); everything else uses system fills and controls.

## Today's gaps (generated)
- Raw status colors in views (measured before the rename: 59 `.secondary`, 8 `.orange`, 7 `.green`, 5 `.red`); to be replaced by `LintelBrand` tokens.
- 42 hard-coded `.callout` fonts; long explanatory footers.
- Three places show microphone permission; model download rows are duplicated per plugin.

<!-- uxproof:manual-start -->
## Manual rules (refreshed for Lintel, 2026-11-05; supersedes the 2026-11-04 set)

**Direction: native, with a signature.** Floating surfaces (launcher panel, HUDs, menu) keep Liquid Glass. The main window (Settings, Notes) uses system fills and controls only: **no glass in the window**. The brand shows up in three places only: one accent colour, the app icon / menu bar glyph, and the motion and illustration of onboarding and HUDs. No gradients, no purple-blue "AI" palette, no glow, no sparkle icons.

**Brand is approved.** Name Lintel. `brand.accent` #267C6C (light) / #6BBDAB (dark), for fills, caret, bars and graphics (3:1). `brand.accent.text` #036152 / #6BBDAB, for accent used as text (4.5:1). Colour is flat. The old name appears only on lines marked LEGACY-POUNCE (bundle id `app.pounce.*`, Keychain services, defaults domain, migration code).

**Colour only through `LintelBrand`.** Raw colours (`.orange`, `.red`, `.green`, ...) are forbidden in views (see `guards.json`; a source-scanning test in `LintelAppTests` enforces it in CI). In Settings panes status goes only through the host's `StatusBanner`; workspace sections draw their strips with `LintelBrand` `status.*` tokens (ok / attention / error / neutral). Text only through `TextSize` tokens (title / body / help). Spacing from 2, 4, 8, 12, 16, 24.

**Archetypes.** `workspace-window`: one window, sidebar with groups, detail area. `settings-pane`: StatusBanner (what works, one Fix action) → Basics → Advanced disclosure → Data (Clear / Erase, always with a confirmation dialog). A permission is always shown by one shared `PermissionRow`. Models live in one Models pane; plugin panes only summarise them.

**Copy.** English base and Polish, every key in both (`StringCatalogTests`). Sentences are short (about 15 words); detail goes in `.help` or Learn more. Buttons are verbs ("Download", "Allow Microphone"). Errors say what happened and what to do.

**Motion and accessibility.** Animations respect Reduce Motion. Full keyboard path: sidebar, banner action, rows, Advanced disclosure. State changes are announced to VoiceOver. Contrast is checked in light, dark and XL text. At XL the window keeps its minimum width, panes scroll and the sidebar never truncates a group label.

**Done means:** screenshots in light and dark at S and XL, in English and Polish, before a UI PR merges.
<!-- uxproof:manual-end -->
