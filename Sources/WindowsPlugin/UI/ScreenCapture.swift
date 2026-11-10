import AppKit

/// What the plugin's overlay panels (the zone overlay, the HUD, the display identifier) say to screen sharing and
/// capture. They are never shown in screen sharing or recordings (`.none`), the shipped behaviour. A DEBUG build can
/// make them capturable for QA (`plugins.windows.qaCapturable`) so the overlay, HUD and identifier can be
/// photographed (the menu bar strip is a status item and was never excluded); release builds have no such switch and
/// always answer `.none`.
///
/// Invariant of the DEBUG switch: it is process-global state, written only by `WindowsPlugin.init` from the plugin's
/// own setting before any panel exists, and read when a panel is created. In a normal run there is one plugin
/// instance, so there is one value; tests that flip it do so synchronously on the main actor and put it back.
@MainActor
enum ScreenCapture {
    #if DEBUG
    /// Set by the plugin from `plugins.windows.qaCapturable` (DEBUG builds only).
    static var qaCapturable = false
    #endif

    static var sharingType: NSWindow.SharingType {
        #if DEBUG
        qaCapturable ? .readOnly : .none
        #else
        .none
        #endif
    }
}
