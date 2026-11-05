# Pounce design conventions

Generated sections describe the code today; the manual section below is the team's rule and wins on conflict.

## Stack (generated, by hand: the web extractor does not read Swift)
SwiftUI inside AppKit windows (`NSPanel`, `NSWindow`), macOS 26, Liquid Glass (`NSGlassEffectView`, `.glassEffect`) on the launcher panel and the dictation HUD. Settings is `NSTabViewController` (toolbar style) hosting SwiftUI `Form(.grouped)` panes, 600 pt wide. No asset catalog and no custom accent: everything uses the system accent.

## Today's gaps (generated)
- Raw status colors in views: 59 `.secondary`, 8 `.orange`, 7 `.green`, 5 `.red`.
- 42 hard-coded `.callout` fonts; long explanatory footers.
- Three places show microphone permission; model download rows are duplicated per plugin.

<!-- uxproof:manual-start -->
## Manual rules (decided 2026-11-04)

**Direction: native Liquid Glass with a signature.** Keep Liquid Glass on floating surfaces (launcher panel, HUDs). Settings and welcome use system controls and the grouped Form. The brand shows up in three places only: one accent color, the app icon / menu bar glyph, and the motion and illustration of onboarding and HUDs. No gradients-on-everything, no purple-blue "AI" palette, no neon glow, no sparkle icons.

**Brand is pending.** Name, logo and palette are being decided. Tokens `brand.*` are `pending-brand`: never invent values. The product name is not final, so user-visible strings must not hard-code "Pounce" where a bundle display name works. Renaming touches protected surfaces (bundle id `app.pounce.*`, Keychain services, defaults domain, TCC grants, `PluginID`s): that needs its own spec and BACKWARD_COMPATIBILITY review, not a find-and-replace.

**Tokens are semantic and raw colors are forbidden in views** (see `guards.json`). Status = ok / attention / error / neutral. Text = title / body / help, all scaled by `TextSize`. Spacing from 2, 4, 8, 12, 16, 24.

**Settings structure.** Sidebar with groups (Pounce, Search, Voice, Models, Advanced). Each plugin pane starts with a status banner ("Ready" / "N things left" with one Fix button). Basics first, rare options behind Advanced. A permission is always shown by one shared `PermissionRow`. Models live in one Models pane; plugin panes only summarise them.

**Copy.** English base and Polish, every key in both. Sentences in the UI are short (about 15 words); detail goes in `.help` or Learn more. Buttons are verbs ("Download", "Allow Microphone"). Errors say what happened and what to do.

**Motion and accessibility.** Animations respect Reduce Motion; contrast checked in light, dark and XL text; everything reachable by keyboard; state changes announced to VoiceOver.

**Done means:** screenshot in light and dark at S and XL, in English and Polish, before a UI PR merges.
<!-- uxproof:manual-end -->
