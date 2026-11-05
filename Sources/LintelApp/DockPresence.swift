import AppKit

/// Lintel is a menu bar app (`LSUIElement`), and by default it also has an icon in the Dock: the activation
/// policy is switched at runtime from the `app.showInDock` setting.
enum DockPresence {
    static func policy(showInDock: Bool) -> NSApplication.ActivationPolicy {
        showInDock ? .regular : .accessory
    }

    /// What a click on the Dock icon (or opening the app again from Finder) does.
    enum ReopenAction: Equatable {
        /// Open Settings: the Dock icon is where the app's own windows live; the launcher has its shortcut.
        case openSettings
        /// A window is already open: AppKit brings it forward.
        case nothing
    }

    static func reopenAction(hasVisibleWindows: Bool) -> ReopenAction {
        hasVisibleWindows ? .nothing : .openSettings
    }

    static func apply(showInDock: Bool, to application: NSApplication = .shared) {
        let policy = policy(showInDock: showInDock)
        guard application.activationPolicy() != policy else { return }
        application.setActivationPolicy(policy)
    }
}
