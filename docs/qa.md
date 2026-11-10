# QA mode

Lintel is a native app that reads the clipboard, indexes files and stores a key in the Keychain.
QA runs (manual or agent-driven) must never touch the tester's real data. DEBUG builds therefore
accept launch arguments that isolate a run; release builds compile the parsing out
(`Sources/LintelApp/QA/QAOptions.swift` is wrapped in `#if DEBUG`), so the arguments do nothing in a
shipped app.

## Launching

```bash
swift build
.build/debug/Lintel --qa --qa-appearance dark --qa-show-menu --qa-quit-after 8
```

Or build a bundle (ad-hoc signed, never with the "Lintel Release" identity locally) and run its binary:

```bash
CONFIGURATION=debug scripts/make-app.sh
dist/Lintel.app/Contents/MacOS/Lintel --qa --qa-show-menu --qa-quit-after 8
```

The menu appears with the process's localization; run with `-AppleLanguages '(pl)'` to check the
Polish strings without changing system settings.

## What QA mode changes

Any `--qa…` argument turns QA mode on:

| Concern | Normal run | QA mode |
|---|---|---|
| Data root | `~/Library/Application Support/Lintel` | `--qa-data-root <path>`, or a fresh `$TMPDIR/lintel-qa-<uuid>` |
| Settings | `UserDefaults` domain `com.lintelapp.Lintel` | in memory; no defaults domain is written |
| Keychain | file-based login keychain | in memory; the real `com.lintelapp.clipboard` item is never created or read |
| Pasteboard | `NSPasteboard.general` | private named pasteboard `com.lintelapp.qa.<pid>` |
| Global hotkeys | registered | never registered, so ⌘Space and ⌘⇧V stay with the tester; the shortcut recorders show the would-be shortcut from the volatile registration domain |
| Caches | `~/Library/Caches/Lintel` | `Caches/` under the data root |
| Focus | the panel and the main window activate Lintel | windows are ordered front without activating Lintel or taking key focus, and the panel does not close when another app has focus |
| Launch at Login | `SMAppService.mainApp` | in memory; the toggle never registers anything |
| Paste keystroke | ⌘V posted to the previous app (needs Accessibility) | never posted; the paste is only logged |
| File index | the home folder and `/Applications` | only `plugins.files.roots`, resolved against the fake home `plugins.files.qaHome`; both default to an empty `files-home/` folder in the data root, so the real home and `/Applications` are never scanned |
| Full Disk Access | read by listing `~/Library/Safari` and similar folders | `--qa-full-disk-access`, default `denied`; the real state is never read |
| App activity (suggestions) | `Plugins/apps/activity.json`, filled by app switches and a one-time Spotlight seed | `activity.json` under the QA data root, filled only from `--qa-activity`; the tracker and the seed run only with `--qa-activity-live` |

AppKit itself may still write window and status-item state to the `com.lintelapp.Lintel` defaults domain.
If that domain did not exist before a QA session, remove it afterwards with
`defaults delete com.lintelapp.Lintel`.

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
| `--qa-window workspace\|settings` | Main window, step 1.2 | Open the main window in that mode. Workspace mode falls back to Settings while no workspace section is registered. |
| `--qa-settings general\|features\|permissions\|advanced\|models\|<plugin id>` | Phase 1, plugin panes Phase 2, `permissions` and `advanced` Phase 4, `models` main window step 3.2 | Select that pane in the main window's Settings mode, for example `clipboard`. With `--qa-window settings` the window opens on that pane. |
| `--qa-onboarding` | Phase 1; the whole welcome screen since Phase 4 | Show the welcome screen with every page (introduction, Shortcut, every active plugin's step), whatever was completed. |
| `--qa-fail-action` | Phase 1 | With `--qa-panel`: once results load, show the failed-action message for the selected row's first action without running it. |
| `--qa-confirm-action` | main window 6.2 | With `--qa-panel <list mode>`: once results load, show the "Press ⌃X again to delete" footer of the selected row's delete (the first action with a confirmation) without running it and without the 5 s timeout. |
| `--qa-spotlight on\|off` | Phase 1 | Pretend Spotlight does or does not hold ⌘Space instead of reading the system's symbolic hotkeys. |
| `--qa-onboarding-step <step id>` | Phase 2; the welcome screen since Phase 4 | Show the welcome screen on one page: `intro`, `shortcut`, a plugin step such as `clipboard.intro`, or the final page `done` ("You're set", which opens the main window). The welcome screen is the single-column layout of the prototype `shell-welcome-*`. |
| `--qa-pasteboard-access allow\|default\|ask\|deny` | Phase 2 | The pasteboard access behaviour plugins see (`NSPasteboard.accessBehavior`), for the clipboard's permission banners. |
| `--qa-accessibility granted\|denied` | Phase 2 | The Accessibility status plugins see. Without it the real status is read, never changed. |
| `--qa-full-disk-access granted\|denied` | Phase 3 | The Full Disk Access status plugins see (default `denied` in QA mode). Never read from, or changed in, the system. |
| `--qa-about` | Phase 4 | Open the About window. |
| `--qa-activity <bundle ID>[=<uses>]` | App suggestions | Record `<uses>` (default 1) app uses of that bundle ID, at launch time, in the empty QA activity store (repeatable), so the empty panel shows "Suggested". The bundle ID must belong to an app under `plugins.apps.roots`. |
| `--qa-activity-live` | App suggestions | Run the real activity tracker and the one-time Spotlight seed in QA mode (off by default, so a QA run never records the tester's app switches). |
| `--qa-meeting-mic-wav <path>` | Meeting notes 1.5 | A 16 kHz mono WAV (16-bit PCM or 32-bit float) played back as the meeting's microphone track instead of the real microphone. Options parsing only until the plugin is registered (step 1.10). |
| `--qa-meeting-system-wav <path>` | Meeting notes 1.5 | The same for the system-audio track; real Core Audio capture is never started in QA mode. |
| `--qa-meeting-spool-dir <path>` | Meeting notes 1.5 | Folder for the encrypted spool of QA meetings instead of `<data root>/Plugins/meetings/Spool`. The Keychain is the in-memory one in QA mode, so the spool key never reaches the real Keychain. |

Unknown `--qa…` arguments stop the launch with an error, so a typo never silently falls back to real
data.

## Clipboard history with fake entries

QA mode never reads the tester's clipboard: the plugin watches the private pasteboard
`com.lintelapp.qa.<pid>`, and its key lives in the in-memory keychain, so no `com.lintelapp.clipboard` item is
created. To fill the history with fake entries (text, a link, a note, two `/tmp/lintel-demo/` file
paths, a generated picture), seed it with `plugins.clipboard.qaSeed=demo`. Seeding only fills an empty
history and exists only in DEBUG builds. The same setting replaces the default ignored apps with fake
ones (`com.example.*-demo`) and stops the settings pane from looking up installed apps, so a screenshot
never shows which apps (for example which password manager) the tester has installed. Always pass it
when capturing the Clipboard History settings pane.

```bash
dist/Lintel.app/Contents/MacOS/Lintel --qa --qa-setting plugins.clipboard.qaSeed=demo \
  --qa-accessibility granted --qa-panel clipboard --qa-appearance light
# Recording paused, Accessibility missing, access set to ask:
dist/Lintel.app/Contents/MacOS/Lintel --qa --qa-setting plugins.clipboard.qaSeed=demo \
  --qa-setting plugins.clipboard.paused=true --qa-accessibility denied --qa-pasteboard-access ask \
  --qa-panel clipboard
# Empty history, settings pane, onboarding step:
dist/Lintel.app/Contents/MacOS/Lintel --qa --qa-accessibility granted --qa-panel clipboard
dist/Lintel.app/Contents/MacOS/Lintel --qa --qa-setting plugins.clipboard.qaSeed=demo --qa-settings clipboard
dist/Lintel.app/Contents/MacOS/Lintel --qa --qa-onboarding-step clipboard.intro
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
dist/Lintel.app/Contents/MacOS/Lintel --qa \
  --qa-setting "plugins.apps.roots=$FIXTURES" --qa-setting plugins.apps.spotlight=false \
  --qa-record-use apps:com.example.notes --qa-panel search --qa-query no --qa-appearance dark
```

`plugins.apps.roots` replaces the default roots (`/Applications`, `~/Applications`,
`/System/Applications`, `/System/Library/CoreServices/Applications`). Fake bundles have the generic
app icon.

In QA mode the shortcut recorders are read-only. KeyboardShortcuts would write a recorded shortcut to
the `com.lintelapp.Lintel` defaults domain and register it with the system, so a QA run cannot record one.

## App suggestions

The "Suggested" section lists apps from the activity store, and only apps the index knows. Give QA
mode fixture bundles (as above) and record uses of their bundle IDs with `--qa-activity`; uses of a
bundle ID that is not under `plugins.apps.roots` are kept but never suggested. More uses rank higher;
all uses are recorded at launch time.

```bash
FIX=/tmp/lintel-sugg-qa/apps
for app in Mail:com.example.mail Notes:com.example.notes Maps:com.example.maps Music:com.example.music; do
  mkdir -p "$FIX/${app%%:*} Demo.app/Contents"
  plutil -create xml1 "$FIX/${app%%:*} Demo.app/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string "${app#*:}" "$FIX/${app%%:*} Demo.app/Contents/Info.plist"
done
COMMON=(--qa --qa-setting "plugins.apps.roots=$FIX" --qa-setting plugins.apps.spotlight=false
  --qa-activity com.example.mail=5 --qa-activity com.example.notes=3 --qa-activity com.example.maps)
# The empty panel with "Suggested" (⌘1–⌘3 open the rows, ⌃X hides the selected one):
dist/Lintel.app/Contents/MacOS/Lintel "${COMMON[@]}" --qa-panel search --qa-appearance dark
# Suggested and "Recently Used" without duplicates:
dist/Lintel.app/Contents/MacOS/Lintel "${COMMON[@]}" --qa-record-use apps:com.example.mail \
  --qa-record-use apps:com.example.music --qa-panel search
# Settings → Apps (Suggest Apps, hidden apps, Clear App Activity…), with one hidden app:
dist/Lintel.app/Contents/MacOS/Lintel "${COMMON[@]}" \
  --qa-setting plugins.apps.suggestions.hidden=com.example.maps --qa-settings apps
# Suggestions turned off: no section, the history stays:
dist/Lintel.app/Contents/MacOS/Lintel "${COMMON[@]}" --qa-setting plugins.apps.suggestions.enabled=false \
  --qa-panel search
```

The "Running" badge comes from the real running apps, so fixture bundles never show it; check it by
hand with a real app (for example `--qa-setting plugins.apps.roots=/System/Applications --qa-activity
com.apple.Notes` while Notes is open). With `--qa-activity-live` the tracker records the tester's real
app switches into the QA data root only. The newer-version message in Settings → Apps needs an
`activity.json` with `"version": 2` in `<data root>/Plugins/apps/` (pass `--qa-data-root`).

## File search with a fixture folder

The file index would otherwise list the tester's own file names. QA mode always replaces the home
folder with a fake one (`plugins.files.qaHome`, DEBUG builds only) and indexes only
`plugins.files.roots`; without them both point at an empty folder in the data root. Build a fixture
tree of fake names under `/tmp/lintel-p3-*` and point both settings at it. Use folders and `.txt`
files only: a file's icon comes from the app that opens it, so other types (`.md`, `.pdf`, `.csv`,
`.html`) can show which editor, PDF viewer or browser the tester has installed.

```bash
FIX=/tmp/lintel-p3-qa
mkdir -p "$FIX/home/Projects/Website" "$FIX/home/Desktop" "$FIX/home/Documents" "$FIX/apps"
touch "$FIX/home/Projects/Quarterly Report.txt" "$FIX/home/Projects/Website/notes.txt" \
  "$FIX/home/Desktop/desk-plan.txt" "$FIX/home/Documents/tax-form.txt"
dist/Lintel.app/Contents/MacOS/Lintel --qa \
  --qa-setting "plugins.files.qaHome=$FIX/home" --qa-setting "plugins.files.roots=$FIX/home" \
  --qa-setting plugins.files.setupCompleted=true --qa-full-disk-access denied \
  --qa-setting "plugins.apps.roots=$FIX/apps" --qa-setting plugins.apps.spotlight=false \
  --qa-panel search --qa-query report
# The Full Disk Access onboarding step and the Files settings pane:
dist/Lintel.app/Contents/MacOS/Lintel --qa --qa-setting "plugins.files.qaHome=$FIX/home" \
  --qa-onboarding-step files.fullDiskAccess
dist/Lintel.app/Contents/MacOS/Lintel --qa --qa-setting "plugins.files.qaHome=$FIX/home" \
  --qa-setting plugins.files.setupCompleted=true --qa-settings files
```

Without `plugins.files.setupCompleted=true` the panel shows the "set up file search" notice instead
of indexing. With `--qa-full-disk-access denied`, Desktop, Documents and Downloads of the fake home
are skipped and the panel shows the "no Full Disk Access" notice; `granted` indexes them. The result
order (Settings → Features → Result Order) is seeded with a comma-separated list, for example
`--qa-setting app.sectionOrder=files,apps`.

### Path mode

A query that starts with `/` or `~` lists that folder straight from disk, including hidden and excluded
folders (file path search spec). In QA mode `~` is the fake home, so build the folders there:

```bash
mkdir -p "$FIX/home/Projects/ng/.ai/runs/2026-10-27-qa-fixes/screenshots" "$FIX/home/Documents/Invoices"
touch "$FIX/home/Projects/ng/.ai/runs/2026-10-27-qa-fixes/plan.txt" \
  "$FIX/home/Projects/ng/.ai/runs/2026-10-27-qa-fixes/.hidden.txt" "$FIX/home/Documents/Invoices/march.txt"
dist/Lintel.app/Contents/MacOS/Lintel --qa \
  --qa-setting "plugins.files.qaHome=$FIX/home" --qa-setting "plugins.files.roots=$FIX/home" \
  --qa-setting plugins.files.setupCompleted=true --qa-full-disk-access denied \
  --qa-panel search --qa-query "~/Projects/ng/.ai/runs/2026-10-27-qa-fixes/"
# Filter after the last slash, and a protected folder without Full Disk Access (only its row, with a note):
#   --qa-query "~/Projects/ng/.ai/runs/2026"      --qa-query "~/Documents/Invoices/"
```

Hidden items inside the listed folder appear only when the filter starts with a dot or "Include hidden
files" is on (Settings → Files). Without Full Disk Access, path mode never opens Desktop, Documents, Downloads, iCloud
Drive, `/Volumes/*` or `~/Library/(Group )Containers`; check by hand that typing
`/Volumes/<USB stick>/`, `~/Pictures/Photos Library.photoslibrary/` and `~/Library/Containers/<app>/`
shows no privacy prompt. Known limit: a file opened through path mode in a hidden or excluded folder
is recorded, but it does not appear in "Recently Used" (an empty query), which lists indexed items only.

## Welcome screen, Permissions, Advanced and About (Phase 4)

Settings → Permissions lists the permissions of the enabled plugins with the states QA mode reports, so
pass the states to show (the real Accessibility state is read when `--qa-accessibility` is missing;
pass it to keep the screenshot independent of the tester's Mac). The panes never open System Settings
unless a button is clicked.

```bash
FIX=/tmp/lintel-p4-qa; mkdir -p "$FIX/home" "$FIX/apps"
COMMON=(--qa --qa-setting "plugins.files.qaHome=$FIX/home" --qa-setting "plugins.files.roots=$FIX/home"
  --qa-setting "plugins.apps.roots=$FIX/apps" --qa-setting plugins.apps.spotlight=false
  --qa-setting plugins.clipboard.qaSeed=demo --qa-spotlight off)
# The welcome screen, from the first page or on one page:
dist/Lintel.app/Contents/MacOS/Lintel "${COMMON[@]}" --qa-onboarding
dist/Lintel.app/Contents/MacOS/Lintel "${COMMON[@]}" --qa-onboarding-step shortcut
# Settings → Permissions and Advanced:
dist/Lintel.app/Contents/MacOS/Lintel "${COMMON[@]}" --qa-accessibility denied --qa-full-disk-access granted \
  --qa-pasteboard-access ask --qa-settings permissions
dist/Lintel.app/Contents/MacOS/Lintel "${COMMON[@]}" --qa-settings advanced
# About (the notices come from the bundle, so use the app built by make-app.sh):
dist/Lintel.app/Contents/MacOS/Lintel --qa --qa-about
```

Add `-AppleLanguages '(pl)'` for the Polish strings and `--qa-appearance light|dark` for each appearance.
"Reset Ranking…" in QA mode empties only the QA data root's `ranking.sqlite`.

## Accessibility audit (spec step 4.3)

Phase 4 audited every screen against the spec's accessibility criteria (UI/UX → Dostępność). What the
code does, so a regression is easy to spot:

| Criterion | Where it is handled |
|---|---|
| Result list is a VoiceOver list of labelled rows | `ResultList` (container "Results"), `ResultRow` (label = title, value = kind and path or source app, `isSelected`) |
| Selection and result count are announced | `PanelModel.moveSelection` announces title and kind; the count is announced after 500 ms without typing; filter changes and "Copied" are announced |
| Footer keys are spoken in words | `ActionFooter.spokenLabel` ("Show in Finder, Command-Return") |
| Reduce Motion | the panel's 120 ms fade is skipped (`PanelController`); no other animations |
| Reduce Transparency, Increase Contrast | the panel and bubble use the system glass (`NSGlassEffectView`), which follows both settings; with Increase Contrast the selected row and every filter chip get an outline |
| Differentiate Without Colour | matched characters are always bold; the selected filter chip gets a checkmark; every permission and feature state has a symbol and text |
| Text size (S–XL) | the panel, its list modes and the confirmation bubble scale with Settings → General → Text size; at XL titles wrap instead of truncating |
| Keyboard access | every Settings and welcome control is a standard control reachable with Tab when Keyboard Navigation is on; the welcome screen takes Return (Continue) and Esc (Skip) |
| Repeated buttons name their target | "Erase Data of Files…", "Add Desktop"; each "Open System Settings…" in Permissions has the hint "Opens Accessibility in System Settings" |
| Page changes are announced | the welcome screen announces "Step 2 of 4: Shortcut"; Reset Ranking announces its result |

Still manual, for a person with VoiceOver and Accessibility Inspector (checklist in the Phase 4 PR):
an Accessibility Inspector audit of the panel, Settings (every pane), the welcome screen and About
without errors; a VoiceOver pass through the same screens; the panel with Reduce Transparency and
Increase Contrast turned on in System Settings; the segmented text-size control read as words; and Tab
order with Keyboard Navigation on.

## Screenshots

Capture only Lintel's own windows, never the full screen:

1. Find the window ids owned by the process (`CGWindowListCopyWindowInfo`, owner name `Lintel`).
2. `screencapture -x -o -l <window id> out.png` for each.
3. Open every image before attaching it to a PR, and discard any that shows anything other than
   Lintel and the fake data of the run.

## Dictation

The microphone grant is tied to the app's code signature. Every ad-hoc rebuild (`scripts/make-app.sh`) has a
new signature, so macOS asks for the microphone again (and the Accessibility grant also has to be renewed
for Command-V to work). Both are manual QA items: the QA flags isolate settings, data and shortcuts, but the
microphone permission, a real recording, the real model (about 630 MB, downloaded from Settings → Models) and
pasting into another app cannot be faked. Check the HUD, the Settings pane and the setup step with
`--qa --qa-panel`-style runs, and everything that records or pastes by hand.

### Dictation formatting (Phase 2)

The formatting server is the user's own, so it cannot be faked in CI. With Ollama (or LM Studio,
llama-server) running and a model pulled, turn on Settings → Dictation → Basics → Clean up text and check:

- the server and model are found and chosen by themselves, "Try it" shows a cleaned sample;
- an address such as `http://example.com` or `192.168.1.5` is refused in the Address field;
- dictate a long text in Polish, English and mixed; spoken questions and commands come back as cleaned
  questions and commands, never answered;
- stop the server and dictate: the raw text is pasted and the HUD says "Pasted – not cleaned up";
- "Paste raw version of the last dictation" (menu bar) pastes the transcript without formatting.

Run the prompt fixtures against a server (prints the input, output and time of each case):

```sh
LINTEL_LLM_URL=http://127.0.0.1:11434 LINTEL_LLM_MODEL=qwen3:4b \
  swift test --filter CleanupFixtureTests/realServer
```

### Dictation history (Phase 3)

Needs a real Keychain and the app built by `scripts/make-app.sh` (not `--qa`, which isolates the Keychain):

- dictate a few times (raw and cleaned); menu bar → Dictation History lists them newest first, with the first sentence and the age; the preview switches between Formatted and Raw;
- Return pastes the cleaned text into the app you came from, ⌘Return the raw one, ⌃X deletes; ⌘1/⌘2/⌘3 filter All/Formatted/Raw; a word only in the raw transcript ("yyy") is found;
- Settings → Dictation → History: switch it off (new dictations are not saved, the list says it is off), change "Keep for" and "At most", "Clear History…" asks first and empties the list;
- Keychain Access shows one `com.lintelapp.dictation` item; Settings → Features → Dictation → Erase Data removes it and the `Plugins/dictation` folder (downloaded models in `Models/` stay; "Remove model" deletes them);
- delete the `com.lintelapp.dictation` item by hand and relaunch: the old file is renamed `dictation.sqlite.unreadable-<date>` and the history starts empty.

## Meetings audio sources (manual)

The real Core Audio tap (`CoreAudioProcessTapBackend`) is compiled but never exercised by `swift test`: a tap shows the
system-audio consent prompt and captures real audio. Everything around it (conversion to 16 kHz mono, gap filling,
device-change handling, timeline alignment, the self-test verdicts, echo suppression) is covered by unit tests with a
scripted fake backend. Check the real thing by hand with the app built by `scripts/make-app.sh` (not `--qa`, which
isolates the Keychain; audio permissions are per app, not per `--qa` data folder):

- **Denial yields zero buffers.** Start a tap (Settings, test button, or the record command once it exists) and deny the
  consent prompt (or remove Lintel from System Settings, Privacy & Security, "System Audio Recording Only"). The tap
  still starts, but every buffer is zeros. The self-test must say there is no audio ("check the permission") and the
  meeting HUD must show the hint after 20 s of a silent system track while the microphone keeps recording. Granting the
  permission again and re-running the self-test says it works.
- **Bluetooth headphones.** Record while playing audio; connect or disconnect AirPods (or switch the default output in
  System Settings, Sound) mid-recording. The system track must continue within about a second, the gap is silent, and
  the transcript times of the microphone and system tracks stay aligned (speak a clap or a count on both sides). Do it
  twice in a row and with the headset connecting while no audio plays.
- **Echo.** Listen through the speakers (no headphones) to a remote speaker and check that the same sentence does not
  appear on both tracks (`EchoSuppressor`).
- **Confirm the privacy pane id.** ADR 0007 item 4 leaves `Privacy_AudioCapture` unconfirmed. Open
  `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture` and note whether it lands on the "System
  Audio Recording" list. If it does not, record the correct id in the ADR and in the Permissions deep link.
- **Permission lost after an ad-hoc rebuild.** With ad-hoc signing the code signature changes on every build, so macOS
  forgets the system-audio consent: after rebuilding, the self-test goes back to "no audio" until the prompt is accepted
  again (remove the stale Lintel entry first if the prompt does not come back). Release builds signed with the stable
  "Lintel Release" certificate keep it.
- **Default shortcut and VoiceOver (manual).** The default ⌃⌥M is also VoiceOver's modifier (⌃⌥ = VO). With
  VoiceOver on, ⌃⌥M may be consumed by VoiceOver instead of reaching Lintel. Check once with VoiceOver running
  that the command starts and stops a recording, and if it does not, record the finding in the PR (the shortcut
  can be changed in Settings → Meetings; the spec'd default stays).
- **Setting.** `plugins.meetings.systemAudio` off records the microphone only and never creates a tap (no prompt).
- **Cleanup.** After stopping a recording, `Audio MIDI Setup` shows no leftover "Lintel meeting tap" aggregate device.

## Meetings (Phase 1)

The plugin is off by default: turn it on with `--qa-setting plugins.meetings.enabled=true`, or in Settings → Features.
The Keychain is the in-memory one in QA mode, so the library key never reaches the real Keychain, and the data root is
fresh unless `--qa-data-root` is given. Real capture is never started in QA mode: the audio comes from WAV files.

Options that matter (see the table above for all of them):

- `--qa-meeting-mic-wav <path>` and `--qa-meeting-system-wav <path>`: 16 kHz mono WAV played back as the two tracks;
- `--qa-meeting-spool-dir <path>`: where the encrypted spool of the QA meeting goes;
- `--qa-panel meetings.library [--qa-query <text>]`: the library list mode; `--qa-settings meetings`: the settings pane;
- `--qa-appearance light|dark`, and `-AppleLanguages '(pl)'` for the Polish strings.

```sh
CONFIGURATION=debug scripts/make-app.sh
APP=dist/Lintel.app/Contents/MacOS/Lintel
# The library with meetings in it needs recorded or seeded meetings: record one from the WAV files first
# (run the record command from the menu, stop it, wait for "ready"), keeping --qa-data-root so the next run sees it:
$APP --qa --qa-data-root /tmp/lintel-qa-meetings --qa-setting plugins.meetings.enabled=true \
  --qa-meeting-mic-wav mic.wav --qa-meeting-system-wav system.wav --qa-show-menu --qa-quit-after 120
# The library, the Keychain-unavailable and empty states are shown by the next runs:
$APP --qa --qa-data-root /tmp/lintel-qa-meetings --qa-setting plugins.meetings.enabled=true \
  --qa-panel meetings.library --qa-appearance dark --qa-quit-after 8
$APP --qa --qa-setting plugins.meetings.enabled=true --qa-panel meetings.library --qa-quit-after 8   # empty library
```

States to screenshot, in light and dark mode (and once in Polish):

- the HUD while recording (both tracks, the level, the hint after 20 s of a silent system track) and while finishing;
- the meeting window (transcript with times, speakers, a rename, the banners for `incomplete`, `failed` and stale notes);
- the library: ⌃X asks first in the panel footer ("Delete this meeting? Press ⌃X again to delete · Esc cancels",
  within 5 s; the shell's confirmation, step 6.2 of the main-window spec) and a meeting being recorded or processed
  says it cannot be deleted; the
  "Needs Attention" filter shows incomplete and failed meetings, and also meetings whose notes failed or are
  outdated (a deliberate extension of the spec's incomplete/failed/stale list); the audio claim on the landing page
  and in Settings → Permissions matches the behaviour (deleted once the transcript is ready; an interrupted
  meeting keeps its audio up to 7 days so it can be finished); all meetings, the three filters (⌘1 to ⌘3), a search by a word from a title and from a transcript (also
  without Polish letters: `budzet` finds `budżet`), the preview (notes when there are any, else the transcript), the empty
  library, and the "unavailable" banner (cannot be forced in QA mode: the Keychain is the in-memory one; covered by
  unit tests, manual check below);
- Settings → Meetings (models, retention, privacy actions) and Settings → Permissions with the system-audio test.

Checks that cannot be done in a `--qa…` run (listed as manual items in the PR): microphone and system-audio consent
prompts and denial; real Zoom, Meet and Teams meetings; speakers without headphones (echo) and Bluetooth headsets
(route changes); the 3 h soak (memory, disk, CPU); diarization quality for Polish; the consent lost after an ad-hoc
rebuild; the library with a locked or denied Keychain (lock the login keychain, open the library: the banner says it is
unavailable and nothing is deleted; unlock and reopen); ⌃X in the library on a real meeting; the landing page in a
browser (`.ai/browsers/agent-browser.md`), in English and Polish.

### Meeting notes (Phase 2): the flow, the corpus and the real-model run

Notes need a downloaded GGUF model from `LLMModelCatalog` (2.5 GB for the default one), so a `--qa…` run of the notes
is manual and uses a real model; nothing in `swift test` loads one.

Flow to check, in light and dark mode and once in Polish (`-AppleLanguages '(pl)'`):

- Settings → Meetings → Notes: the switch is off on a fresh profile and `plugins.meetings.notesEnabled` stays unset until
  you flip it; the model list shows only models that fit this Mac's memory (an 8 GB Mac lists the small one only), with
  the download size and the memory; with a stored model that does not fit, the pane says which one is used instead;
  Download shows progress and can be cancelled, Remove is refused while notes are being written or dictation uses the
  model.
- The `meetings.setup` step has an optional notes row: nothing is downloaded until the button is pressed.
- With the switch on and the model present, stop a recording: the library row shows "Writing notes 1 of N", then
  "Notes". With the model missing it shows "Notes model needed" and the row has a "Download Notes Model" action (also a
  banner and button in the meeting window) that opens Settings; only meetings that finished in this session with notes on
  and the model missing get it, older ones show nothing, and downloading the model does not write notes for old
  meetings by itself (use Regenerate Notes). Dictate with the built-in model while notes run: the notes' generation is
  cancelled between two tokens, the model is reloaded for dictation (a few seconds the first time; at most one copy
  is in memory), the dictation is formatted, and the notes take the model again afterwards and repeat the interrupted
  step (the badge may say "Waiting for the model" for up to a few seconds meanwhile). Dictating with another model file
  while notes run gives the raw text (the model is busy) and the notes keep running.
- ⌘R and "Regenerate Notes" work on `ok`, `partial`, `failed` and `stale` notes; renaming a speaker marks them
  outdated (also during the first generation: the notes then appear outdated and are written again by themselves);
  a partial run never replaces complete notes (they stay, marked as from an earlier run); a failed run keeps the earlier text and says so in the preview; "N points not backed by the recording were
  left out" shows in the preview and the window (check 1, 2, 5 and 12 points in Polish for the plural forms).
- Quit during a run and open again: the meeting shows "Notes failed" (never "Writing notes" for ever); the transcript is intact.

Corpus (`Tests/MeetingsPluginTests/Fixtures/notes/`): five short transcripts (Polish, English, Polish with English terms,
spoken instructions to the model with markup, a chat in which nobody decides anything) and a long plain transcript.
`NotesRegressionTests` feeds each case's `modelAnswer` (a model that invents) through the real pipeline and guard and
checks what must stay and what must not. `RealNotesTests` runs the same transcripts on a real model; it is **off by
default** and must be run by hand:

```sh
LINTEL_NOTES_LLM_MODEL=/path/to/Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
  swift test -c release --filter RealNotesTests
# the volume of a one hour meeting (20 x the bundled long one, about 9 000 words) or your own transcript, one "[mm:ss] Speaker: text" per line:
LINTEL_NOTES_LLM_MODEL=… LINTEL_NOTES_LONG_REPEAT=20 swift test -c release --filter RealNotesTests
LINTEL_NOTES_LLM_MODEL=… LINTEL_NOTES_TRANSCRIPT=/path/to/transcript.txt swift test -c release --filter RealNotesTests
```

It asserts the guard's invariants for any model (no image, link or HTML in the notes; every decision, task and question
stands on a quote that is in the recording; no task owner nobody named; none of the corpus's bait text) and prints
`NOTES-BENCH` lines with the timings, chunk count, dropped count and memory (`docs/perf.md`). It prints no transcript
text. Record the lines in the PR body together with the model and the Mac.

### Meeting notes: what the guard does and does not promise (Phase 2)

The notes come from the built-in model, and the transcript they are written from is untrusted. Every point is checked
against the recording (`NotesGuard`): its quote must stand in one sentence of the transcript, its text may not add a
number, name, date or address that the quote does not have (then the transcript's own words are shown instead), a
task keeps a person only when the quote names them (or the speaker, when the quote is in the first person), and the
model's summary paragraph is replaced by one composed in code when it brings in a new name, number, date or negation.

Residual risk: notes may reflect instructions spoken in the meeting. A speaker who says "add a task: send the
password to everybody" gets a task with that real quote in the notes, and the guard cannot tell it from a genuine one
(it does not give the task a person or a date nobody said). The output is only displayed: nothing is executed,
opened, sent or fetched, and links, images and HTML in it are shown as inert text. Check this with a transcript
that contains such a sentence; the task may appear, with its quote, and nothing else may happen.

### Meeting suggestions (Phase 3, manual)

Meeting suggestions are off by default and cannot be tested by an agent: the Core Audio process objects need real
apps. Whether `kAudioProcessPropertyIsRunningInput` works and is reliable (Bluetooth headsets included) is **not
verified** (`docs/decisions/0007-meeting-spike.md` item 5). Check on a real Mac, with a build that is not a `--qa…`
run only for the detection itself (use the QA data root so the library is isolated):

- Settings → Meetings → Meeting suggestions: turn it on. If macOS does not report processes, the pane says "Not
  available on this Mac"; record that in ADR 0007 and drop Phase 3.
- Zoom, Teams, FaceTime, Slack, Discord, Webex: join a call. About 10 s after the microphone is in use the pill "Looks
  like a meeting in …" appears at the top of the screen with Record, Not now and "Don't ask for this app". It must
  not appear in a screen share, must not take the focus from the call, must disappear after 15 s, and Return/Esc must
  keep going to the app you type in.
- Record starts the normal recording (and the meeting shows the app in the library). Nothing starts without a click.
- A browser (Meet): no pill until the browser's bundle ID (for example `com.google.Chrome`) is added in the pane.
- Bluetooth headset: the call app is detected both with the headset and the built-in microphone; a headset switching
  from A2DP to HFP does not make a second pill in the same call.
- Dictation (⌃⌥D) and recording a meeting never make a pill. Leaving and rejoining a call gives one new pill.
- Muted app: "Don't ask for this app" stops pills for it; Settings → Meetings lists it and "Ask again" brings it back.
- After a recording started from a pill: leave the call and stay quiet; about 60 s later the pill asks "End the
  recording?" (End recording / Keep recording); it never ends the recording by itself.
- Turn the setting off while a pill is showing: the pill disappears and no further pills come.
- Honest limits to confirm: a Safari/WebKit-helper-based app may not be detected; the pill is not operable from the
  keyboard (it claims no keys on purpose) but VoiceOver reads it and can press its buttons.
- If no app reports microphone use for 30 s after turning the setting on, the pane says "Lintel cannot confirm that
  detection works on this Mac" (not "Not available"); starting a call then clears it.
- A headset or mute flap (mic use stops and restarts within 30 s) gives no second pill; a pill answered "Not now" does
  not come back for the same call. Two apps joining together give one pill, the second after the first is answered.

## Window management: manual items (real Mac, Accessibility granted)

The engine is tested against a scriptable fake client (`Tests/WindowsPluginTests/WindowEngineTests.swift`, also under
Thread Sanitizer in CI). What only a real Mac can show is listed here and is filled in with the spike results in
`docs/decisions/0009-window-management-spike.md`. The plugin is registered (off by default) since step 1.12, so these
run with it switched on.

**QA mode.** `--qa-windows` (DEBUG) gives window management a fake client with five fake windows and two fake displays
(`Sources/LintelApp/QA/QAWindowClient.swift`); without it QA mode reports no windows, never the real ones. Combine with
`--qa-settings windows`, `--qa-accessibility granted|denied`, `--qa-setting plugins.windows.enabled=true` and
`--qa-appearance light|dark`. Example: `Lintel --qa --qa-windows --qa-accessibility granted --qa-setting plugins.windows.enabled=true --qa-settings windows`.

**Real windows under QA.** `--qa-real-windows` (DEBUG) selects the real `AXWindowClient` instead of the fake one while
keeping every other isolation (temporary data root, in-memory Keychain, no global hotkeys); give the tester's own apps a
pass with `--qa-setting plugins.windows.floatingApps=<comma-separated bundle ids>` (a list setting). Hotkeys stay off
because the shortcut library keeps its recorded shortcuts in the real defaults domain. `--qa-persistent-settings` keeps
the QA settings in `<data root>/qa-settings.json` (inside the isolated root; command-line `--qa-setting` values win at
every launch), so a second launch sees what the first stored. `--qa-setting plugins.windows.qaCapturable=true` (DEBUG
only) makes the zone overlay, the HUD and the display identifier capturable for screenshots (the menu bar strip is a
status item and was never excluded); release builds always keep them out of screen sharing (`ScreenCapture`).
`--qa-setting plugins.windows.qaDragTrace=<file>` (DEBUG only) appends one line per snap drag with the time of each
stage from the engine receiving the first moved event to the overlay being ordered in
(`ingest`, `flushStart`, `read`, `reportedOnMain`, `targets`, `overlayShown`, in ms): the part before `ingest` is the
Accessibility notification reaching Lintel and is read from the outside (the window's first move).
The Layouts window keeps its frame in the plugin settings (`plugins.windows.layoutsWindowFrame`), never in the window
system's autosave.

**Menu bar strip QA.** `--qa` DEBUG runs add `qa windows stripRects` (the screen rect of every box, so a tester can click the real boxes) and the setting `plugins.windows.qaStripTrace` (logs what a click delivers: event x, location in the window, the cursor position, the item frame and the mapped x). QA pass 3 showed that the system delivers a status item's click at the item's centre, so every click read as the middle box; the controller therefore maps the click from where the mouse went down on the item (a local monitor), else the cursor's screen position (`StripLayout.resolvedClickX`); when neither is inside the item (VoiceOver, Voice Control) it opens the strip's menu instead of choosing a box. This is verified by tests with the observed numbers, **not yet on a real menu bar**; each box is also an accessibility element with its selected state, and the system's menu bar item may still show no children to a tester's Accessibility inspector. The one-item-per-box fallback remains the owner's manual decision.

**QA command route.** `--qa-command-file <path>` (DEBUG, only in a `--qa` run) starts a poller (every 50 ms) that reads
one line at a time from that file, runs it through the commands the shortcuts use, and appends `ok | <line>` or
`error: <why> | <line>` to `<path>.log`. A line is a command id of an active plugin (`windows.workspace.2`,
`windows.moveToWorkspace.3`, `windows.focus.left`, `windows.move.right`, `windows.resize.grow`, `windows.toggleLayout`,
`windows.zones.nextLayout`, `windows.zones.layout.3`, `windows.zones.zone.2`, `windows.restoreAllWindows`, ...) or
`qa windows <verb>`: `resetState`, `restoreAll`, `snap <zone number>` (snaps the focused window as a drag released over
that zone would), `import <path>`, `export <selected|all> <path>` (the mode comes first, so the rest of the line is the path; an unknown mode is an error), `addFloating <bundle id>`, `openLayouts`. Lines that
start with `#` and empty lines are ignored; a line is run when its newline arrives, and only whole lines are decoded. The route starts at the end of an existing file, so a relaunch does not replay an earlier run: `--qa-command-replay` runs what is already in it. A file that was replaced or rewritten (a different file, or different bytes where the last read ended) is read again from its start. A QA run never opens an open or save
panel (they write their sizes and the Go To sheet's frame into the real defaults domain): files and the "Add App…"
picker are scripted by the verbs above (`plugins.windows.qaScriptedFiles`, on in every `--qa` run).

| # | Scenario | Expect |
|---|---|---|
| 1 | Switch workspaces with 20 windows of 5 apps | Windows of the old workspace disappear into the bottom right corner, the new ones return to their frames, no flicker; the budget in `docs/perf.md` holds. |
| 2 | Frame rounding on a Retina display | A restored window reads back the same frame within the echo tolerance (2 points); no loop of moves. |
| 3 | An app that hangs (`kill -STOP` its process), then switch; `kill -CONT` it and switch again | The other apps' windows still move; the hung app's windows stay where they are (their park timed out), are **kept** by the engine even if a resync/Space-change snapshot is taken while the app does not answer (a read that fails is "unknown", never "closed": `WindowClient.readWindows` reports `unreachable`/`unreadable` from the failed read itself, and the engine looks again by itself, after 5 s, 10 s, 20 s... up to every 60 s, until the app answers; only for an app the engine holds a window of), and are parked and tiled again on the next switch or event after the app answers; "Copy diagnostics" counts the Accessibility timeouts. A window that really closed (the app answers and no longer lists it) is still removed. (QA 2026-11 found the windows dropped for good; fixed in round 9, regression tests `WindowEngineTests`, `EngineReducerTests`.) |
| 4 | Unplug and replug an external display, change its resolution | Workspaces of the removed display are parked on the remaining one; parked windows are re-parked in the new corner; everything returns when the display does. |
| 5 | Kill Lintel (`kill -9`) while windows are parked, start it again (plugin on, then plugin off) | Parked windows come back at launch in both cases. |
| 6 | An app that re-centres its hidden window (some Electron apps) | The window is hidden again at most three times, then left alone until focused; no flicker loop; the watchdog does not trip. |
| 7 | Stage Manager on; "Displays have separate Spaces" off | The banners in Settings name the problem (keys verified in ADR 0009). |
| 8 | Real `_AXUIElementGetWindow` self-check (ADR 0009 row 7) | With Accessibility granted and a few windows open the plugin starts; a missing symbol makes the pane show "Update Lintel". |
| 9 | Menu bar strip (single status item): click each box, right-click, VoiceOver on the boxes, fill the menu bar | Each click switches to that box; boxes read "Workspace 3, 4 windows" and the current one is also announced as selected, once; with no room the banner says so. **If the click mapping or the accessibility children do not work, the fallback (one status item per box, at most nine) is a manual decision of the owner**, not taken automatically. |
| 10 | Accessibility off: press ⌥2 | The HUD says "Allow Accessibility to switch workspaces" with a button; nothing moves. Grant it with windows parked: they come back within about 2 s. |
| 11 | Keyboard layout check on a Polish layout (⌥ plus a letter types a letter) and on US | The pane and the welcome step name keys that type a letter and offer ⌃⌥; none for the digit keys. With Auto-tile (step 2.5) ⌥L (focus right) and ⌥⇧L (move right) are named on a Polish layout; "Use ⌃⌥" moves every family (go, move to workspace, focus, move, resize) and the warning goes. ⌥- and ⌥= type symbols, never letters, so they are never named. |
| 12 | Safe mode: leave windows parked (kill -9) on two launches in a row | The third start shows "Switched off after a problem" with its own explanation (not the generic "This feature couldn't start"); Try Again starts it. With `--qa-persistent-settings` the two-launch counter can be tried under QA isolation. |
| 13 | Real AX observers: create, move, resize, close, minimise and fullscreen windows of 5 apps | The engine follows (look at "Copy diagnostics"); no event storm; fullscreen exit manages the window again (reported as a resize). |
| 15 | An app that is slow to become scriptable (launch one with a long start) | Its notifications are added on retry (after 1, 2 and 4 s); its windows are still seen through the engine's snapshot meanwhile. |
| 16 | Auto-tile (default layout) with 4 windows of 3 apps on one display: open a window, close one, switch workspaces and back | A new window lands after the focused one; a closed window's space goes to its neighbours; the tiles fill the display's visible frame with the gaps from Settings (default 8 pt) and never overlap; a workspace that was not shown tiles when it is shown. Nothing is arranged before Accessibility is granted. |
| 17 | ⌥H/J/K/L focus, ⌥⇧H/J/K/L move, ⌥- and ⌥= resize, with the windows of an app that has a minimum size | Focus follows the tiles; a move swaps, enters a neighbouring split or leaves its own; resize changes the share by 5 % and stops at 10 %. A window that refuses its tile size is centred in the tile once and never chased. |
| 18 | Join, toggle split direction, toggle floating, balance (unbound by default; bind them in Settings or run them from a custom binding) | Join stacks a window with its neighbour; toggling floating releases the window and the others refill; it returns after the previously focused window. Balance gives every tile the same share. |
| 19 | Drag or resize a tiled window by hand | It is not snapped back while you drag; the next structural change (window opened or closed, workspace shown, a command) places it on its tile again. Record how this feels: the spec does not say whether a drag should snap back at once. |
| 20 | Floating apps: add an app in Advanced, then open its window; remove the default Calculator from the list | The app's windows are left where they are; Calculator then tiles. Lintel's own windows and System Settings are never tiled by default. |
| 21 | Per-workspace overrides (Advanced, *Edit* on a workspace): kind Free, gaps 0, first split Stacked | Free leaves the windows where they are, with the tiling state kept; switching back to Auto-tile tiles again. The summary line of the workspace matches what is on screen. |
| 22 | Toggle layout command (⌥/) | Cycles the current workspace through Auto-tile, Zones and Free; the per-workspace line in Advanced shows the override and it disappears when the kind equals the default. Every kind's state is kept: Zones back to Auto-tile restores the same tree and the same zone placement. |
| 24 | Zones with the fake client (`--qa-windows`, `--qa-setting plugins.windows.defaultKind=zones`, optionally `--qa-setting plugins.windows.defaultZoneLayout.landscape=stock.grid2x2`) | The five fake windows fill the zones of the layout on the first fake display in join order, the rest stack in the focused zone; `windows.zones.zone.N` (bind one in Settings first) and ⌥⇧H/J/K/L move the focused window between zones. The fake client emits no events, so dragging cannot be tried there. |
| 25 | Real Shift-drag snapping (Zones workspace, two apps): drag a window with the title bar, press Shift before and after the drag starts, release over a zone, release Shift first, release outside every zone; also select text and drag a file in Finder with Shift held | The overlay appears within 150 ms of the first drag event (`docs/perf.md`; the budget is end to end and includes the app's own Accessibility notification delay) over the display that shows the workspace only while the left button is down and Shift is held and a managed window moves; the zone under the cursor is highlighted and VoiceOver says "Zone 2"; release snaps the window to that zone; releasing Shift first, or the button away from every zone, snaps nothing; text selection and Finder drags never show it. The panels never take focus or a click. Pointer, Shift and button are read with `NSEvent.pressedMouseButtons`, `.modifierFlags` and `.mouseLocation` on a 60 Hz timer that runs only during a drag: this needs no permission (a global `flagsChanged` monitor would need Accessibility, and no monitor can consume events), so there is none. Record any case where the overlay lags the cursor. |
| 26 | The one-time hint: switch a workspace to Zones for the first time with Accessibility granted | A HUD says "Hold ⇧ while dragging to snap" once, never again (hidden setting `plugins.windows.snapHintShown`). Not shown without Accessibility. |
| 27 | Overlay on two displays, with a display above or left of the main one, Increase Contrast, Reduce Transparency, light and dark, English and Polish | Zone numbers sit on opaque pills and meet contrast over any wallpaper; the highlighted zone differs by border weight and pill fill, not by colour alone; the panel covers its own display exactly (coordinates are converted between the Accessibility space and Cocoa's). Attach screenshots as PR evidence. |
| 23 | Fake client (`--qa-windows`, plugin on, Accessibility granted) | The five fake windows tile on the first fake display at once (use `--qa-setting plugins.windows.defaultKind=free` to see them untouched, `--qa-setting plugins.windows.gap.inner=0` for no gaps); the focus, move and resize shortcuts and the Advanced editor drive them in memory. The fake client emits no events, so opening and closing windows needs a real Mac (row 16). |
| 28 | Layouts window (Settings → Window Management → Layouts…, or `--qa-setting plugins.windows.qaOpenLayouts=true` in a DEBUG build with `--qa-windows`): pick layouts per cell, *Apply to…*, change a workspace's kind, *Identify*, arrow keys, ⌫ and 1 to 6 on the matrix | The labels read "Columns 2 · default" until a cell is chosen; every change is written to `assignments.json` at once and the windows re-arrange; *Apply to…* writes the chosen cells; the kind menu of a workspace follows Settings (a kind equal to the default clears the override); *Identify* shows the display's number for two seconds on that display; with the plugin off the window says so and nothing can be edited. Check the smallest and largest text size, light and dark, English and Polish, VoiceOver on a cell ("Workspace 2, Display 2, Columns 2 · default") and Full Keyboard Access on the pickers. |
| 29 | Two identical monitors (same UUID) in the Layouts window | The note says they are told apart by position; each column keeps its own assignment after a restart. |
| 30 | Layout editor (Layouts window → *New layout* or *Edit…* on one of Mine): click zones to divide them, ⇧-click, ⌘-click two zones and *Merge*, drag a divider, change a zone's x, y, width and height fields, *Undo*/*Redo*, ⌘S, Esc | The sheet opens over the Layouts window; a live preview of the same zones is drawn over the chosen display (and follows every edit, also on a second display chosen in the picker); a drag is one undo step; refused edits say why in the red line (for example "Those zones don't make one rectangle"); *Save* adds or replaces the layout and the Layouts window selects it; Esc on a clean editor closes it, with changes it asks "Discard your changes to this layout?". Record the time to open (`docs/perf.md`). |
| 31 | Editor with the keyboard and VoiceOver only | Tab walks the zones, then the vertical and horizontal dividers, and leaves the canvas at both ends; S and ⇧S divide (down to a track of 1% of the display, then the editor says it cannot get narrower; a click divides only into pieces of at least 5%, so a track under 10% is divided with the keys or the numeric fields), Space selects, M merges, arrows move a divider by 1%, Delete on a divider merges its neighbours (or says they don't line up); VoiceOver reads each zone-list row as "Zone 2, x 25%, y 0%, width 50%, height 100%", dividers as "Vertical divider at 50%" with increment and decrement, and the zone list has *Divide side by side* / *Divide stacked* actions. Check the smallest and largest text size, light and dark, English and Polish, Increase Contrast. |
| 32 | Switch Window Management off while the editor has unsaved changes | The editor asks to discard; *Keep editing* leaves it open with the note "Window Management is off…", *Save* still saves and closes; a clean editor closes at once. |
| 33 | Layout library: Duplicate a stock layout, Rename, Delete one that two cells use, Import a file, Export one layout and all of mine | Delete names the number of cells and up to six of them and says "This can't be undone."; after it the cells show "<default> · default"; Import shows the summary sheet before anything is added and refuses oversize, newer-version and malformed files with a message; Export writes a `.lintellayouts` file that imports into another Mac without slots or assignments. |
| 34 | Layout slots (Settings → Window Management → Advanced → Layout slots) and *Next Zone Layout* | Bind a layout to a slot and record a shortcut: it gives the current workspace on the focused display that layout at once (the Layouts window matrix shows it); an unbound slot does nothing; *Next Zone Layout* walks the stock templates and then Mine and wraps; with Accessibility off the HUD asks for it and nothing changes. |
| 35 | Double-click a `.lintellayouts` file in Finder (Lintel running, then not running) | Lintel opens the Layouts window with the import summary; nothing is added until *Import*; with the plugin off the window says so. Finder shows Lintel as the app for the file type. |
| 14 | `swift`-side screenshots: Settings pane, HUD, strip in light and dark, smallest and largest text, English and Polish | Attach as PR evidence (not captured by an agent without a display, see the PR). |

## Never during QA

- No synthetic key events, no `tccutil`, no edits to TCC databases or `com.apple.*` defaults.
- No toggling Launch at Login (`SMAppService`).
- No signing with the "Lintel Release" identity on a developer machine (see `docs/signing.md`).
- Quit every Lintel process you started.

Checks that need TCC grants (Accessibility for paste, a real Full Disk Access grant, the privacy prompt
for a folder added one at a time), a full-screen app, a second display or Space switching are manual
QA items listed in the PR body.

## Meetings: owner manual test plan (hardware, permissions, real apps)

Nothing below was run by the implementing agents: they have no microphone, no System Audio Recording consent,
no real meeting apps, no Bluetooth gear and no long-running soak. Always launch with the isolating `--qa…`
options from this file unless the item says it needs real data (then use a throwaway macOS user or accept
that the test touches your real Lintel data). Remember that ad-hoc builds lose the System Audio Recording
grant after every rebuild.

1. **Microphone and system audio, real calls.** Record a Zoom, a Google Meet and a Teams call: the HUD shows
   both meters, the transcript has both sides, "Ja"/"Mówca N" labels are plausible. Check the macOS consent
   prompt wording and that `Privacy_AudioCapture` really opens the right pane (ADR 0007 item 4).
2. **Denials.** Deny the microphone (offer "system audio only"), deny System Audio Recording (HUD hint after
   20 s, "Test System Audio" says "silent"), revoke it after an update.
3. **Speakers without headphones (echo).** The same sentence must not appear twice; measure
   `EchoSuppressor` thresholds on real ASR output; compare `voiceProcessing` on/off (not wired yet).
4. **Bluetooth.** Switch output A2DP/HFP mid-recording: tap recreated, timeline continuous, no second
   suggestion pill.
5. **Soak 3 h.** Memory during and after (idle < 150 MB once models are released), disk (spool <= ~700 MB,
   deleted at `ready`), CPU < 15% average, the 2 h 50 min countdown and automatic stop; fill the disk to
   test the 1.5 GB / 300 MB guards.
6. **Diarization.** Quality for Polish (one online, one live meeting); memory and time for 1 h and 3 h
   (`docs/perf.md`; the 90 min per-track cap is unmeasured), the fallback to "Ja / Inni" and its banner;
   real model load through `FluidDiarizer.loadModels` (never exercised by tests); binary size delta.
7. **Notes.** Run `RealNotesTests` with a real GGUF (see "Notes" above) on a strong and a weak Mac; timings,
   8192-context memory, quality of the Polish map/reduce output, "N punktów bez pokrycia" counts; dictate
   while notes run (takeover/resume, reload cost, 15 s grace).
8. **Crash and quit.** Kill Lintel during a recording and during processing; relaunch: `incomplete`,
   "Dokończ", resume to `ready`, spool deleted; Keychain item deleted by hand; ⌘Q mid-recording.
9. **Coexistence with dictation.** Same speech model (shared lease) and different models ("Another speech
   model is in use"); whether macOS lets both use the input device ("Trwa nagrywanie spotkania" is not
   implemented on the dictation side).
10. **Meeting suggestions.** Zoom, Teams, FaceTime, Slack, Discord, Webex; a browser added by hand; WebKit
    helper apps; whether `kAudioProcessPropertyIsRunningInput` exists and is reliable (including Bluetooth);
    pill in a real screen share (must be invisible); the "no data yet" status.
11. **Updates.** Update from the previous release with downloaded models (migration `Plugins/dictation/{Models,llm}`
    → `Models/{speech,llm}`), and Accessibility / Full Disk Access / Keychain surviving an in-place update
    (`codesign -dr -` identical, BC §4). Roll back to the old build: models must be downloaded again.
12. **Visual and accessibility pass** in light/dark and S–XL text: HUD, meeting window, library list mode and
    preview, Settings → Meetings (audio, models, notes, suggestions, privacy), onboarding step
    `meetings.setup`, Permissions row with the "Test" accessory; VoiceOver, keyboard-only, Reduce Motion.
13. **Shortcuts.** ⌃⌥M (VoiceOver modifier clash), ⌃⌥D; the status-bar menu entries.
14. **Known unrelated flake:** `AppsPluginTests` `SuggestionsLifecycleTests/theSeedWaitsForTheFirstFinishedScan`
    depends on live Spotlight on the test machine.
