# Execution plan: Phase 2 clipboard history (Pounce MVP)

Source doc: .ai/specs/2026-10-31-pounce-launcher-mvp.md
Branch: feat/clipboard-plugin (base: feat/apps-plugin, stacked on #4, which is stacked on #3)

## Goal

Ship Phase 2 of the MVP spec (v0.2): an encrypted clipboard history opened with ⌘⇧V that pastes the
chosen entry into the previous app, together with every safety control in the same version (clear
history, ignored apps, retention, permission banners, pause recording, `accessBehavior` support).

## Scope

- `ClipboardPlugin` target and `ClipboardPluginTests`, registered with one line in `PluginRegistry`:
  - `KeyStore`: master key in the file-based login keychain through `KeychainClient`
    (`service = app.pounce.clipboard`), HKDF-SHA256 sub-keys (`sqlcipher`, `blob`, `content-hash`),
    `errSecItemNotFound` as the only reset path (archive `clipboard.sqlite.unreadable-<date>`, kept
    30 days); every other error disables history and deletes nothing.
  - `PasteboardWatcher` (0.5 s `changeCount` loop on the main actor, stops while disabled or paused,
    honours `accessBehavior`), `CaptureFilter` (nspasteboard.org markers, ignored apps, 20 MB limit,
    own writes), typed entries (text, rich, image, file, URL).
  - `ClipStore`: SQLCipher `clipboard.sqlite` in `Plugins/clipboard/` with its own migrator,
    `clip_item` / `clip_representation` / `clip_fts`, HMAC `content_hash` dedupe, AES-GCM blob files
    over 1 MB with random UUID names, deletion of rows together with blob files.
  - `RetentionJob`: 30 days or 1000 entries by default, at activation and hourly, orphan sweep.
  - Clipboard panel mode (⌘⇧V): list with source-app icon and time, preview, ⌘1–⌘5 type filter,
    search (FTS5 + fuzzy over recent entries), ⌃X delete, frecency from `use_count` /
    `last_used_at`.
  - `PasteService`: Return pastes through ⌘V when Accessibility is granted, otherwise copies;
    Secure Event Input and a closed previous app fall back to copying with a "Copied" message.
  - Settings pane (shortcut recorder, pause, retention, ignored apps, Clear History, access and
    Keychain state), menu bar commands (Clipboard History, Pause/Resume Recording), onboarding step.
- `PounceKit` additions, additive only with defaults (R8): pasteboard read/write and access
  behaviour, frontmost-app details and session activation on `WorkspaceClient`, list panel modes
  (`PanelModeSource`, filters, preview, empty state), `ResultAction.keepsPanelOpen`,
  `PluginContext.makeShortcutRecorder`.
- `PounceApp`: list-mode rendering and keyboard (⌘1–⌘5, ⌃X), 480 pt clipboard mode, "Copied"
  confirmation, plugin onboarding steps, per-command shortcut recorders (issue #5), command shortcuts
  in the menu, keyboard-layout-aware ⌘V key code, QA flags.
- Spike 2.2 (`NSPasteboard` reads off the main thread) with an ADR.
- Docs: `docs/qa.md`, `docs/decisions/0002-pasteboard-reads.md`, `AGENTS.md`,
  `BACKWARD_COMPATIBILITY.md` settings keys; `en` + `pl` strings.

## Non-goals

- File search (Phase 3); Permissions and Advanced panes, welcome screen (Phase 4).
- User-defined section order (issue #5): only one search section exists until Phase 3; stays open in
  #5 unless it turns out to be trivial.
- Pinning entries, OCR, sync (out of MVP scope).
- The `om-auto-review-pr` loop (a separate reviewer runs it).

## Implementation Plan

### Phase 1: Contracts and key store

1.1 Additive `PounceKit` contracts for clipboard capture, list panel modes, per-command recorders,
with contract tests.
1.2 `ClipboardPlugin` target, registry line, `KeyStore` with HKDF sub-keys and the reset policy
(spec step 2.1). Test: Keychain mock for every error code; only `itemNotFound` resets.

### Phase 2: Capture and storage

2.1 Spike 2.2, `PasteboardWatcher` and `CaptureFilter` (spec step 2.2). Test: named pasteboard,
change during the read, markers, ignored apps, size limit, own writes.
2.2 `ClipStore` with representations, HMAC dedupe, encrypted blobs and FTS5 (spec step 2.3).
2.3 `RetentionJob` (spec step 2.6). Test: fake clock, temporary directory, orphan sweep.

### Phase 3: Panel mode and paste

3.1 Shell support for list panel modes (preview, filters, ⌘1–⌘5, ⌃X, 480 pt, confirmation message).
3.2 Clipboard panel mode with list, preview, filter, search and delete (spec step 2.4).
3.3 `PasteService`, copy-only fallbacks, layout-aware key code, Accessibility banner (spec step 2.5).

### Phase 4: Safety controls, onboarding, docs

4.1 Clipboard settings pane, menu commands, pause, `accessBehavior` and Keychain states, per-command
shortcut recorder (spec step 2.7, issue #5).
4.2 Clipboard onboarding step and shell support for plugin onboarding steps.
4.3 QA flags and fake clipboard data, docs, `en` + `pl` strings.

### Phase 5: Verification

5.1 Full validation gate and CI green.
5.2 Native UI evidence (light/dark, en/pl) posted on the PR.

## Risks

- Spike 2.2: `NSPasteboard` is not documented as thread-safe; the fallback (read on the main actor,
  hash and store in the background) is ready.
- Paste needs Accessibility and a real target app: manual QA only. The update-keeps-grant check
  (R1, v0.2.0 → v0.2.1) is manual.
- `accessBehavior` semantics on macOS 26/27 can only be checked partly on a dev Mac without changing
  system settings: unit tests plus a QA flag that fakes the value.

## Progress

PR: #6

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Contracts and key store

- [x] 1.1 Additive PounceKit contracts — 357f114
- [x] 1.2 ClipboardPlugin target and KeyStore — 761fa46

### Phase 2: Capture and storage

- [x] 2.1 Spike 2.2, PasteboardWatcher and CaptureFilter — ff67617
- [x] 2.2 ClipStore — 761fa46, a012704
- [x] 2.3 RetentionJob — f546f1d

### Phase 3: Panel mode and paste

- [x] 3.1 Shell support for list panel modes — ebf7fae
- [x] 3.2 Clipboard panel mode — ece8e2f
- [x] 3.3 PasteService and copy-only fallbacks — ece8e2f, 47396ff

### Phase 4: Safety controls, onboarding, docs

- [x] 4.1 Settings pane, menu commands and per-command recorder — ece8e2f, bda94b9
- [x] 4.2 Clipboard onboarding step — ece8e2f, bda94b9
- [x] 4.3 QA flags, docs and strings — bda94b9, f6bad86, 47396ff

### Phase 5: Verification

- [x] 5.1 Validation gate and CI — 47396ff, 1347e66
- [x] 5.2 Native UI evidence — 1347e66 (PR comment)
