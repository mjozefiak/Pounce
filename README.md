# Pounce

A fast, native macOS launcher with just three things: app search, file search and clipboard history.

> Status: design phase. See the MVP spec in [`.ai/specs/`](.ai/specs/).

- **App search**: fuzzy matching ("vsc" finds Visual Studio Code) that learns from what you pick.
- **File search**: its own in-memory filename index kept fresh with FSEvents, instead of Spotlight.
- **Clipboard history**: encrypted on disk, skips password-manager entries, pastes straight into the previous app.

Built with Swift and AppKit. Free and open source under the [MIT License](LICENSE).
