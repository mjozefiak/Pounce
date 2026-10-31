import KeyboardShortcuts
import SwiftUI

/// The main-shortcut recorder. KeyboardShortcuts stores what the user records; the service then marks the
/// shortcut as user-defined so automatic defaults never replace it.
struct MainShortcutRecorder: View {
    let hotkeys: HotkeyService

    var body: some View {
        KeyboardShortcuts.Recorder(for: .init(HotkeyName.main)) { _ in
            hotkeys.userRecordedMainShortcut()
        }
        .overlay {
            // QA mode: a transparent layer swallows clicks, so the recorder looks as it does in the app
            // (for screenshots) but cannot start recording.
            if !hotkeys.allowsRecording {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(Text("Shortcut to open Pounce", comment: "Accessibility label of the shortcut recorder"))
    }
}

/// Shown while Spotlight holds Command-Space: how to free it, with a deep link to Keyboard Shortcuts.
struct SpotlightShortcutBanner: View {
    static let keyboardSettings = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(
                    "Spotlight uses ⌘Space. To open Pounce with ⌘Space, turn off “Show Spotlight search” in System Settings → Keyboard → Keyboard Shortcuts → Spotlight.",
                    comment: "Banner explaining how to free Command-Space from Spotlight"
                )
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
                    .symbolRenderingMode(.hierarchical)
            }
            if let url = Self.keyboardSettings {
                Link(destination: url) {
                    Text("Open Keyboard Settings", comment: "Button that opens the system's keyboard settings")
                }
            }
        }
    }
}
