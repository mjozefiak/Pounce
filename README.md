# Pounce

A fast, native macOS launcher with just three things: app search, file search and clipboard history.

Website: [mjozefiak.github.io/Pounce](https://mjozefiak.github.io/Pounce/)

## Features

- **App search:** fuzzy matching ("vsc" finds Visual Studio Code) that learns from what you pick, without
  ever ranking a weaker match above a better one.
- **File search:** its own in-memory index of file and folder names in your home folder and
  `/Applications`, kept fresh with FSEvents instead of Spotlight. Names only; Pounce never reads what is
  inside your files.
- **Clipboard history** (⌘⇧V): text, rich text, links, images and files from the last 30 days (up to
  1000 entries), encrypted on disk with SQLCipher and a key in your Keychain. Password managers and
  concealed items are skipped. Return pastes into the app you were using.
- **Keyboard first:** ⌘Space opens the panel (⌃⌥Space while Spotlight keeps ⌘Space), arrows move, Return
  opens or pastes, ⌘Return shows in Finder or only copies, Esc clears and closes.
- **Native and accessible:** Swift, AppKit and SwiftUI with Liquid Glass; light and dark mode; VoiceOver,
  Reduce Motion, Reduce Transparency, Increase Contrast and a text-size setting. English and Polish.
- **Private:** no account, no analytics, no network access. Every feature can be turned off and its data
  erased in Settings.

## Install

Requires macOS 26 or later on Apple silicon.

1. Download **Pounce.dmg** from the [latest release](https://github.com/mjozefiak/Pounce/releases/latest)
   and open it.
2. Drag **Pounce** onto the **Applications** folder.
3. Open Pounce from Applications. A paw appears in the menu bar, and the welcome screen walks you
   through the shortcut and each feature. Every step can be skipped.

### First launch: Gatekeeper "Open Anyway"

Pounce is signed with its own stable certificate ("Pounce Release"), so macOS keeps your permissions
across updates, but it is **not notarized** by Apple. The first time you open it, macOS blocks it. To
allow it once:

1. Open Pounce and close the warning.
2. Open **System Settings → Privacy & Security** and scroll down.
3. Click **Open Anyway** next to the message about Pounce, then confirm with your password or Touch ID.

## Permissions

Pounce never asks for a permission on its own. **Settings → Permissions** lists the ones the enabled
features need, with their state and a button to the right page in System Settings. All are optional:

| Permission | Used by | Without it |
|---|---|---|
| Accessibility | Clipboard history: pasting into the previous app (⌘V) | Return copies the entry; you paste yourself. |
| Full Disk Access | File search: Desktop, Documents, Downloads and iCloud Drive without a prompt per folder | Those folders are skipped; add them one at a time in Settings → Files. |
| Clipboard access (Privacy & Security) | Clipboard history: reading what you copy | If macOS is set to ask or deny, the history shows a notice and records nothing. |

The clipboard history's encryption key lives in your login keychain (service `app.pounce.clipboard`). No
permission is needed; macOS may ask once to allow access.

## Building from source

Requires macOS 26 or later on Apple silicon and Xcode 27 (Swift 6.4).

```bash
git clone --recurse-submodules https://github.com/mjozefiak/Pounce.git
cd Pounce
swift package resolve --disable-keychain   # downloads the SQLCipher binary
swift test
scripts/make-app.sh                        # dist/Pounce.app, signed ad-hoc
scripts/make-dmg.sh --skip-build           # dist/Pounce.dmg
```

A build signed ad-hoc gets a new signature every time, so macOS asks again for its permissions after each
rebuild. Release builds are signed with a stable self-signed certificate so macOS keeps your permissions
across updates; see [docs/signing.md](docs/signing.md).

More documentation: [docs/qa.md](docs/qa.md) (QA mode with fake data), [docs/perf.md](docs/perf.md)
(performance budgets and measurements), [docs/decisions/](docs/decisions/) (architecture decisions) and
the MVP spec in [`.ai/specs/`](.ai/specs/).

## License

Free and open source under the [MIT License](LICENSE). Third-party notices are in
[Resources/THIRD_PARTY_NOTICES.txt](Resources/THIRD_PARTY_NOTICES.txt) and in Pounce's About window.
