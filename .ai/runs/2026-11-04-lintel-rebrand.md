# Lintel rebrand (Pounce → Lintel)

Source doc: `.ai/prototypes/lintel-brand/index.html` (brand design, status: proposal accepted by the owner on 2026-11-04; carried in this PR). Brand decisions are in the owner's brief: name **Lintel**, Verdigris accent, Cut-ring logo.

## Goal

Rename the app from Pounce to Lintel end to end (identity, modules, data locations, strings, docs, landing) and apply the new brand (accent, logo, app icon, menu bar glyph, Dock presence) without losing any data or permission the owner has on their Mac. No public release exists (no tags), so the only installed data is the owner's.

## Scope

**In:**
- Rename SwiftPM targets and directories `PounceKit/Core/Persistence/App` → `LintelKit/Core/Persistence/App`, the executable product `Pounce` → `Lintel`, the protocol `PouncePlugin` → `LintelPlugin`. (`PounceSpeech`, `MeetingsPlugin` and other meeting targets are not on `main`; the rename is a **script** so it can be re-run on those branches after a rebase.)
- Identity: bundle id `app.pounce.Pounce` → `com.lintelapp.Lintel`; Keychain services `app.pounce.{clipboard,dictation}` → `com.lintelapp.*` (and `meetings` in the script for the meetings branches); logger/queue labels; QA flags; Application Support and Caches folder `Pounce` → `Lintel`; signing certificate name in scripts/docs `Pounce Release` → `Lintel Release` (the owner generates the certificate; `designated-requirement.txt` is regenerated then).
- One-time launch migrations: Application Support + Caches folder move, `UserDefaults` domain copy (keys unchanged), Keychain master-key copy per service. Tests for each.
- Brand: Verdigris accent tokens (`brand.accent` light `#267C6C`, dark `#6BBDAB`; `brand.accent.text` light `#036152`), selected-row style, accent caret, `AccentColor`, new Cut-ring mark as a SwiftUI shape, app icon, menu bar template glyph.
- Dock presence: new setting `app.showInDock` (Bool, default true, owner's request) that switches the activation policy at runtime; clicking the Dock icon opens the launcher.
- Strings (EN + PL), About tagline, landing page, README/AGENTS/BACKWARD_COMPATIBILITY and other docs.

**Non-goals:** `PluginID` values, `<plugin id>:<key>` item keys, `app.*` / `plugins.<id>.*` settings keys, database schemas, GitHub repo rename, buying the domain, creating the new signing certificate, historical files in `.ai/specs` and `.ai/runs`.

## Risks

- R1 Parallel work: the meetings plugin (PR #47 and ~15 branches) is not on `main`; the rename will conflict with it. Mitigation: all mechanical changes come from `.ai/scripts/rename-to-lintel.sh`, re-runnable after a rebase.
- R2 Keychain: the new app (different identifier) must read the old item; macOS may ask once. Migration copies bytes and keeps the old item until the new one opens the database.
- R3 TCC grants (Accessibility, Full Disk Access, microphone) do not carry over to a new bundle id: the owner re-grants them on their Mac.
- R4 The domain `lintelapp.com` is not bought yet; the bundle id depends on it. Must be settled before the first release.
- R5 Dock presence changes a protected surface (`LSUIElement` stays in `Info.plist`; policy is switched at runtime). Documented in `BACKWARD_COMPATIBILITY.md`.
- R6 `swift build`/`swift test` time: llama/FluidAudio are not on `main`, builds should be moderate.

## Implementation Plan

### Phase 1: Rename
1.1 Write `.ai/scripts/rename-to-lintel.sh` (idempotent, dry-run mode, covers meetings targets when present).
1.2 Run it on `main`; build, test and format green.

### Phase 2: Migrations
2.1 `LegacyDataMigration`: Application Support/Caches folder move and `UserDefaults` domain copy, with tests.
2.2 Keychain master-key copy (clipboard, dictation) and the `eraseData` interplay, with tests.

### Phase 3: Brand
3.1 `LintelBrand` tokens, accent application, selected-row bar, accent caret, match highlight with `brand.accent.text`.
3.2 `LintelMark` SwiftUI shape used in the empty state, welcome and About; About tagline.
3.3 App icon (`.icns`) + `AccentColor` in `scripts/make-app.sh`, menu bar template glyph.
3.4 `app.showInDock` setting, activation policy, Dock click reopens the launcher, settings toggle, tests.

### Phase 4: Copy and docs
4.1 `Localizable.xcstrings` / `InfoPlist.xcstrings`: English and Polish.
4.2 Landing page, README, AGENTS, BACKWARD_COMPATIBILITY (identity migration, Dock key), CODE_REVIEW, SDLC, docs.

### Phase 5: Verify
5.1 Full gate, TSan subsets.
5.2 Debug app in QA mode: light and dark screenshots of panel, HUD, settings, welcome, About, Dock.
5.3 PR body, review pass.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Rename

- [x] 1.1 Write the rename script — c52d966
- [x] 1.2 Run the rename and get the gate green — d943dc2

### Phase 2: Migrations

- [x] 2.1 Application Support, Caches and UserDefaults migration — 3748024
- [x] 2.2 Keychain master-key copy — 845096a

### Phase 3: Brand

- [x] 3.1 Brand tokens, accent and selection style — e357bea
- [x] 3.2 Lintel mark view, welcome and About — 089e1e9
- [x] 3.3 App icon, AccentColor and menu bar glyph — cac62b0
- [x] 3.4 Dock presence setting — cff0afc

### Phase 4: Copy and docs

- [x] 4.1 Strings in English and Polish — 75d7c2b
- [x] 4.2 Landing page and documents — 2047113

### Phase 5: Verify

- [x] 5.1 Full validation gate — 696857a
- [x] 5.2 QA screenshots in light and dark — 696857a
- [ ] 5.3 PR body and review pass
