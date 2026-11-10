import AppKit

/// What the plugin's overlay panels (the zone overlay, the HUD, the display identifier) say to screen sharing and
/// capture. They are never shown in screen sharing or recordings (`.none`), the shipped behaviour. A DEBUG build can
/// make them capturable for QA (`plugins.windows.qaCapturable`), so the overlay, HUD and strip can be photographed;
/// release builds have no such switch and always answer `.none`.
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
