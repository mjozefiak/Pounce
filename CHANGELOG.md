# Changelog

All notable user-visible changes to Lintel are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each release has a `## [x.y.z] - YYYY-MM-DD`
section (pre-releases use `x.y.z-beta.N`). No version has been released yet.

## [Unreleased]

### Added

- Launcher panel on a global shortcut (Command-Space, or Control-Option-Space when Spotlight holds it) with fast app search, fuzzy matching and frecency ranking.
- App suggestions on an empty query, based on how long each app has been in front.
- File search by name with its own index kept fresh through FSEvents, and path search for queries that start with `/` or `~`. Indexing starts after the Full Disk Access step.
- Clipboard history in an encrypted store, with a list and preview, paste into the previous app, and controls for ignored apps, retention and clearing.
- Dictation with on-device speech recognition, a recording HUD, paste into the active app, an encrypted history, and optional cleanup of the text by a built-in local model or a local server.
- Meeting recording with microphone and system audio, speaker labels and notes written by a local model. Audio and text stay on this Mac.
- Notes workspace that brings meeting notes, transcripts and dictations together, with search, history and restore.
- Window management (off by default).
- Main window, a Settings window with Permissions and Advanced panes (Reset Ranking), and an About window with third-party notices.
- Welcome screen that sets the shortcut and walks through the steps of the features you enable.
- English and Polish interface.

### Changed

- Pounce is now called Lintel, with a new icon and brand colors.
