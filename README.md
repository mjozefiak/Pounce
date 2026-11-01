# Pounce

A fast, native macOS launcher with just three things: app search, file search and clipboard history.

> Status: early development (Phase 0: an empty menu bar app). See the MVP spec in [`.ai/specs/`](.ai/specs/).

- **App search**: fuzzy matching ("vsc" finds Visual Studio Code) that learns from what you pick.
- **File search**: its own in-memory filename index kept fresh with FSEvents, instead of Spotlight.
- **Clipboard history**: encrypted on disk, skips password-manager entries, pastes straight into the previous app.

Built with Swift and AppKit. Free and open source under the [MIT License](LICENSE).

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

Release builds are signed with a stable self-signed certificate so macOS keeps your permissions
across updates; see [docs/signing.md](docs/signing.md).
