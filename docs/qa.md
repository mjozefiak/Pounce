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
| Paste keystroke | ⌘V posted to the previous app (needs Accessibility) | never posted; the paste is only logged |
| File index | the home folder and `/Applications` | only `plugins.files.roots`, resolved against the fake home `plugins.files.qaHome`; both default to an empty `files-home/` folder in the data root, so the real home and `/Applications` are never scanned |
| Full Disk Access | read by listing `~/Library/Safari` and similar folders | `--qa-full-disk-access`, default `denied`; the real state is never read |

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
| `--qa-setting <key>=<value>` | Phase 1 | Seed the in-memory settings (repeatable). `true`/`false` become booleans, integers integers, anything else a string; `app.sectionOrder` (Phase 3) takes comma-separated plugin ids. |
| `--qa-panel <mode>` | Phase 1 | Open the panel after launch without the global hotkey: `search`, or a plugin's panel mode id. |
| `--qa-query <text>` | Phase 1 | Type this query into the panel opened with `--qa-panel`. |
| `--qa-record-use <item key>` | Phase 1 | Record a use of `<plugin id>:<key>` in the QA ranking database before launch (repeatable), so the empty query shows "Recently Used". |
| `--qa-settings general\|features\|<plugin id>` | Phase 1, plugin panes Phase 2 | Open the Settings window on that pane, for example `clipboard`. |
| `--qa-onboarding` | Phase 1 | Show the first-launch Shortcut step. |
| `--qa-fail-action` | Phase 1 | With `--qa-panel`: once results load, show the failed-action message for the selected row's first action without running it. |
| `--qa-spotlight on\|off` | Phase 1 | Pretend Spotlight does or does not hold ⌘Space instead of reading the system's symbolic hotkeys. |
| `--qa-onboarding-step <step id>` | Phase 2 | Show one plugin onboarding step, for example `clipboard.intro`. |
| `--qa-pasteboard-access allow\|default\|ask\|deny` | Phase 2 | The pasteboard access behaviour plugins see (`NSPasteboard.accessBehavior`), for the clipboard's permission banners. |
| `--qa-accessibility granted\|denied` | Phase 2 | The Accessibility status plugins see. Without it the real status is read, never changed. |
| `--qa-full-disk-access granted\|denied` | Phase 3 | The Full Disk Access status plugins see (default `denied` in QA mode). Never read from, or changed in, the system. |

Unknown `--qa…` arguments stop the launch with an error, so a typo never silently falls back to real
data.

## Clipboard history with fake entries

QA mode never reads the tester's clipboard: the plugin watches the private pasteboard
`app.pounce.qa.<pid>`, and its key lives in the in-memory keychain, so no `app.pounce.clipboard` item is
created. To fill the history with fake entries (text, a link, a note, two `/tmp/pounce-demo/` file
paths, a generated picture), seed it with `plugins.clipboard.qaSeed=demo`. Seeding only fills an empty
history and exists only in DEBUG builds. The same setting replaces the default ignored apps with fake
ones (`com.example.*-demo`) and stops the settings pane from looking up installed apps, so a screenshot
never shows which apps (for example which password manager) the tester has installed. Always pass it
when capturing the Clipboard History settings pane.

```bash
dist/Pounce.app/Contents/MacOS/Pounce --qa --qa-setting plugins.clipboard.qaSeed=demo \
  --qa-accessibility granted --qa-panel clipboard --qa-appearance light
# Recording paused, Accessibility missing, access set to ask:
dist/Pounce.app/Contents/MacOS/Pounce --qa --qa-setting plugins.clipboard.qaSeed=demo \
  --qa-setting plugins.clipboard.paused=true --qa-accessibility denied --qa-pasteboard-access ask \
  --qa-panel clipboard
# Empty history, settings pane, onboarding step:
dist/Pounce.app/Contents/MacOS/Pounce --qa --qa-accessibility granted --qa-panel clipboard
dist/Pounce.app/Contents/MacOS/Pounce --qa --qa-setting plugins.clipboard.qaSeed=demo --qa-settings clipboard
dist/Pounce.app/Contents/MacOS/Pounce --qa --qa-onboarding-step clipboard.intro
```

Pasting (Return posts ⌘V into the previous app) needs Accessibility and a real target app, so it is a
manual check outside QA mode. In QA mode the keystroke is never posted: Return writes the entry to the
private pasteboard and logs that ⌘V would have been sent.

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

## File search with a fixture folder

The file index would otherwise list the tester's own file names. QA mode always replaces the home
folder with a fake one (`plugins.files.qaHome`, DEBUG builds only) and indexes only
`plugins.files.roots`; without them both point at an empty folder in the data root. Build a fixture
tree of fake names under `/tmp/pounce-p3-*` and point both settings at it. Use folders and `.txt`
files only: a file's icon comes from the app that opens it, so other types (`.md`, `.pdf`, `.csv`,
`.html`) can show which editor, PDF viewer or browser the tester has installed.

```bash
FIX=/tmp/pounce-p3-qa
mkdir -p "$FIX/home/Projects/Website" "$FIX/home/Desktop" "$FIX/home/Documents" "$FIX/apps"
touch "$FIX/home/Projects/Quarterly Report.txt" "$FIX/home/Projects/Website/notes.txt" \
  "$FIX/home/Desktop/desk-plan.txt" "$FIX/home/Documents/tax-form.txt"
dist/Pounce.app/Contents/MacOS/Pounce --qa \
  --qa-setting "plugins.files.qaHome=$FIX/home" --qa-setting "plugins.files.roots=$FIX/home" \
  --qa-setting plugins.files.setupCompleted=true --qa-full-disk-access denied \
  --qa-setting "plugins.apps.roots=$FIX/apps" --qa-setting plugins.apps.spotlight=false \
  --qa-panel search --qa-query report
# The Full Disk Access onboarding step and the Files settings pane:
dist/Pounce.app/Contents/MacOS/Pounce --qa --qa-setting "plugins.files.qaHome=$FIX/home" \
  --qa-onboarding-step files.fullDiskAccess
dist/Pounce.app/Contents/MacOS/Pounce --qa --qa-setting "plugins.files.qaHome=$FIX/home" \
  --qa-setting plugins.files.setupCompleted=true --qa-settings files
```

Without `plugins.files.setupCompleted=true` the panel shows the "set up file search" notice instead
of indexing. With `--qa-full-disk-access denied`, Desktop, Documents and Downloads of the fake home
are skipped and the panel shows the "no Full Disk Access" notice; `granted` indexes them. The result
order (Settings → Features → Result Order) is seeded with a comma-separated list, for example
`--qa-setting app.sectionOrder=files,apps`.

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

Checks that need TCC grants (Accessibility for paste, a real Full Disk Access grant, the privacy prompt
for a folder added one at a time), a full-screen app, a second display or Space switching are manual
QA items listed in the PR body.
