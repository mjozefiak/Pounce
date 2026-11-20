# Lintel

A fast, native macOS launcher that also keeps your clipboard history, dictates, records meeting notes and
keeps your notes in one place. Everything runs on your Mac.

Website: [lintelapp.com](https://lintelapp.com)

## Features

Lintel is made of plugins. App search, file search, clipboard history and Notes are on by default;
dictation, meeting notes and window management are off until you turn them on.

- **App search:** fuzzy matching ("vsc" finds Visual Studio Code) that learns from what you pick, without
  ever ranking a weaker match above a better one. The empty panel suggests the apps you use most.
- **File search:** its own in-memory index of file and folder names in your home folder and
  `/Applications`, kept fresh with FSEvents instead of Spotlight. Names only; Lintel never reads what is
  inside your files.
- **Clipboard history** (⌘⇧V): text, rich text, links, images and files from the last 30 days (up to
  1000 entries), encrypted on disk with SQLCipher and a key in your Keychain. Password managers and
  concealed items are skipped. Return pastes into the app you were using.
- **Dictation** (off by default): speak anywhere and Lintel pastes the text. Speech recognition runs on
  your Mac. An optional cleanup step uses a small built-in model or a server you run yourself on
  `localhost`. Audio is never written to disk. A history of dictations is kept encrypted.
- **Meeting notes** (off by default): records the microphone and the system audio, transcribes on your
  Mac and writes notes, kept in an encrypted library.
- **Notes:** the main window collects meeting notes, dictations and your own notes, with search, history
  and comments.
- **Windows** (off by default): window management from the keyboard.
- **Keyboard first:** ⌘Space opens the panel (⌃⌥Space while Spotlight keeps ⌘Space), arrows move, Return
  opens or pastes, ⌘Return shows in Finder or only copies, Esc clears and closes.
- **Native and accessible:** Swift, AppKit and SwiftUI with Liquid Glass; light and dark mode; VoiceOver,
  Reduce Motion, Reduce Transparency, Increase Contrast and a text-size setting. English and Polish.
  Lintel lives in the menu bar as a ring with a small cut.

## Privacy and network

No account, no analytics, no tracking. Every feature can be turned off and its data erased in Settings.

Lintel connects to the network only to download the speech and language models you choose to download
(in Settings → Models, or from the download button a feature shows when it needs a model). They come
from Hugging Face (`huggingface.co` and its download servers), pinned to a fixed revision and checked
against a SHA-256 checksum. The optional dictation cleanup can talk to a server on your own Mac
(`localhost` only).

Lintel asks once, after the welcome screen on the first launch, whether it may check for updates. Until you
answer, and after a "no", it makes no update request on its own; Settings → General → Updates has "Check Now"
for when you want one. A check requests `https://lintelapp.com/appcast.xml`, so the site's host sees your IP
address, the Lintel version and the macOS version. No system profile is sent (`SUEnableSystemProfiling` is not set).
There is no other network traffic. Installing from the
[releases page](https://github.com/mjozefiak/lintel/releases) works as before.

## Install

Requires macOS 26 or later on Apple silicon.

1. Download **Lintel.dmg** from the [latest release](https://github.com/mjozefiak/lintel/releases/latest)
   and open it.
2. Drag **Lintel** onto the **Applications** folder.
3. Open Lintel from Applications. A ring with a small cut appears in the menu bar, and the welcome screen walks you
   through the shortcut and each feature. Every step can be skipped.

## Permissions

Lintel asks for a permission only when you use the feature that needs it (the microphone, for example,
on your first dictation or recording). **Settings → Permissions** lists the ones the enabled features need,
with their state and a button to the right page in System Settings. None is needed to start Lintel:

| Permission | Used by | Without it |
|---|---|---|
| Accessibility | Clipboard history: pasting into the previous app (⌘V) | Return copies the entry; you paste yourself. |
| Accessibility | Dictation: pasting the text into the app you are using | The text is copied; you paste yourself. |
| Accessibility | Window management: moving and arranging windows | Windows are not moved; a notice says why and opens the setting. |
| Full Disk Access | File search: Desktop, Documents, Downloads and iCloud Drive without a prompt per folder | Those folders are skipped; add them one at a time in Settings → Files. |
| Clipboard access (Privacy & Security) | Clipboard history: reading what you copy | If macOS is set to ask or deny, the history shows a notice and records nothing. |
| Microphone | Dictation and meeting notes | Dictation does not start; a meeting can record only the system audio. |
| System audio recording | Meeting notes: the other side of a call | Recordings have only your microphone. |

The clipboard history's encryption key lives in your login keychain (service `com.lintelapp.clipboard`). No
permission is needed; macOS may ask once to allow access.

## Building from source

Requires macOS 26 or later on Apple silicon and Xcode 27 (Swift 6.4).

```bash
git clone --recurse-submodules https://github.com/mjozefiak/lintel.git
cd lintel
swift package resolve --disable-keychain   # downloads the SQLCipher binary
swift build
swift test
swift format lint --strict -r Sources Tests
scripts/make-app.sh                        # dist/Lintel.app, signed ad-hoc
scripts/make-dmg.sh --skip-build           # dist/Lintel.dmg
```

A build signed ad-hoc gets a new signature every time, so macOS asks again for its permissions after each
rebuild. Release builds are signed with an Apple Developer ID and notarized, so macOS opens them normally and keeps
your permissions across updates; see [docs/signing.md](docs/signing.md).

Contributions are welcome: read [CONTRIBUTING.md](CONTRIBUTING.md) first, and report security problems
privately as described in [SECURITY.md](SECURITY.md).

More documentation: [docs/qa.md](docs/qa.md) (QA mode with fake data), [docs/perf.md](docs/perf.md)
(performance budgets and measurements), [docs/decisions/](docs/decisions/) (architecture decisions) and
the MVP spec in [`.ai/specs/`](.ai/specs/).

## License

Free and open source under the [MIT License](LICENSE). Third-party notices are in
[Resources/THIRD_PARTY_NOTICES.txt](Resources/THIRD_PARTY_NOTICES.txt) and in Lintel's About window.
