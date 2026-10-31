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
| Global hotkeys | registered | never registered, so ⌘Space and ⌘⇧V stay with the tester; the shortcut recorders show the would-be shortcut from the volatile registration domain |
| Caches | `~/Library/Caches/Pounce` | `Caches/` under the data root |
| Focus | the panel and Settings activate Pounce | windows are ordered front without activating Pounce or taking key focus, and the panel does not close when another app has focus |
| Launch at Login | `SMAppService.mainApp` | in memory; the toggle never registers anything |

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
| `--qa-setting <key>=<value>` | Phase 1 | Seed the in-memory settings (repeatable). `true`/`false` become booleans, integers integers, anything else a string. |
| `--qa-panel <mode>` | Phase 1 | Open the panel after launch without the global hotkey: `search`, or a plugin's panel mode id. |
| `--qa-query <text>` | Phase 1 | Type this query into the panel opened with `--qa-panel`. |
| `--qa-record-use <item key>` | Phase 1 | Record a use of `<plugin id>:<key>` in the QA ranking database before launch (repeatable), so the empty query shows "Recently Used". |
| `--qa-settings general\|features` | Phase 1 | Open the Settings window on that pane. |
| `--qa-onboarding` | Phase 1 | Show the first-launch Shortcut step. |
| `--qa-spotlight on\|off` | Phase 1 | Pretend Spotlight does or does not hold ⌘Space instead of reading the system's symbolic hotkeys. |

Unknown `--qa…` arguments stop the launch with an error, so a typo never silently falls back to real
data. Later phases add, in the same file and this table: seeding the private pasteboard with fake
entries and a fixture directory as the only file-index root.

## App search with fixture apps

The app index would otherwise list every app installed on the tester's Mac. For screenshots, point it
at a directory of fake bundles and turn the Spotlight supplement off:

```bash
mkdir -p "$FIXTURES/Notes Demo.app/Contents"
plutil -create xml1 "$FIXTURES/Notes Demo.app/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string com.example.notes "$FIXTURES/Notes Demo.app/Contents/Info.plist"
# … more bundles …
dist/Pounce.app/Contents/MacOS/Pounce --qa \
  --qa-setting "plugins.apps.roots=$FIXTURES" --qa-setting plugins.apps.spotlight=false \
  --qa-record-use apps:com.example.notes --qa-panel search --qa-query no --qa-appearance dark
```

`plugins.apps.roots` replaces the default roots (`/Applications`, `~/Applications`,
`/System/Applications`, `/System/Library/CoreServices/Applications`). Fake bundles have the generic
app icon.

In QA mode the shortcut recorders are read-only. KeyboardShortcuts would write a recorded shortcut to
the `app.pounce.Pounce` defaults domain and register it with the system, so a QA run cannot record one.

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
