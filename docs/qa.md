# QA mode

Pounce is a native app that reads the clipboard, indexes files and stores a key in the Keychain.
QA runs (manual or agent-driven) must never touch the tester's real data. DEBUG builds therefore
accept launch arguments that isolate a run; release builds compile the parsing out
(`Sources/PounceApp/QA/QAOptions.swift` is wrapped in `#if DEBUG`), so the arguments do nothing in a
shipped app.

## Launching

```bash
swift build
.build/debug/Pounce --qa --qa-appearance dark --qa-show-menu --qa-quit-after 8
```

Or build a bundle (ad-hoc signed, never with the "Pounce Release" identity locally) and run its binary:

```bash
CONFIGURATION=debug scripts/make-app.sh
dist/Pounce.app/Contents/MacOS/Pounce --qa --qa-show-menu --qa-quit-after 8
```

The menu appears with the process's localization; run with `-AppleLanguages '(pl)'` to check the
Polish strings without changing system settings.

## What QA mode changes

Any `--qa…` argument turns QA mode on:

| Concern | Normal run | QA mode |
|---|---|---|
| Data root | `~/Library/Application Support/Pounce` | `--qa-data-root <path>`, or a fresh `$TMPDIR/pounce-qa-<uuid>` |
| Settings | `UserDefaults` domain `app.pounce.Pounce` | in memory; no defaults domain is written |
| Keychain | file-based login keychain | in memory; the real `app.pounce.clipboard` item is never created or read |
| Pasteboard | `NSPasteboard.general` | private named pasteboard `app.pounce.qa.<pid>` |
| Global hotkeys | registered | never registered, so ⌘Space and ⌘⇧V stay with the tester |

AppKit itself may still write window and status-item state to the `app.pounce.Pounce` defaults domain.
If that domain did not exist before a QA session, remove it afterwards with
`defaults delete app.pounce.Pounce`.

## Arguments

| Argument | Since | Effect |
|---|---|---|
| `--qa` | Phase 0 | QA mode with defaults. |
| `--qa-data-root <path>` | Phase 0 | Use this directory as the data root. |
| `--qa-appearance light\|dark` | Phase 0 | Force the app's appearance (`NSApp.appearance`) without touching the system setting. |
| `--qa-show-menu` | Phase 0 | Open the menu bar menu shortly after launch. |
| `--qa-quit-after <seconds>` | Phase 0 | Close any open menu and quit after the delay. |

Unknown `--qa…` arguments stop the launch with an error, so a typo never silently falls back to real
data. Later phases add, in the same file and this table: opening the panel in a given mode with a
given query, seeding the private pasteboard with fake entries, and a fixture directory as the only
file-index root.

## Screenshots

Capture only Pounce's own windows, never the full screen:

1. Find the window ids owned by the process (`CGWindowListCopyWindowInfo`, owner name `Pounce`).
2. `screencapture -x -o -l <window id> out.png` for each.
3. Open every image before attaching it to a PR, and discard any that shows anything other than
   Pounce and the fake data of the run.

## Never during QA

- No synthetic key events, no `tccutil`, no edits to TCC databases or `com.apple.*` defaults.
- No toggling Launch at Login (`SMAppService`).
- No signing with the "Pounce Release" identity on a developer machine (see `docs/signing.md`).
- Quit every Pounce process you started.

Checks that need TCC grants (Accessibility for paste, Full Disk Access), a full-screen app, a second
display or Space switching are manual QA items listed in the PR body.
