import AppKit

/// Lintel is a menu bar app (`LSUIElement`), and by default it also has an icon in the Dock: the activation
/// policy is switched at runtime from the `app.showInDock` setting.
enum DockPresence {
    static func policy(showInDock: Bool) -> NSApplication.ActivationPolicy {
        showInDock ? .regular : .accessory
    }

    /// What a click on the Dock icon (or opening the app again from Finder) does.
    enum ReopenAction: Equatable {
        /// Open the app's window: the main window while it is enabled, else Settings (`MainWindowRouter`). The
        /// Dock icon is where the app's own windows live; the launcher has its shortcut.
        case openMainWindow
        /// A window is already open: AppKit brings it forward.
        case nothing
    }

    static func reopenAction(hasVisibleWindows: Bool) -> ReopenAction {
        hasVisibleWindows ? .nothing : .openMainWindow
    }

    /// Whether a Dock click finds a window of the app already open. The launcher panel and the HUDs are not
    /// windows the Dock brings forward, so with only them visible the main window opens.
    static func hasVisibleWindows(_ roles: [KeyWindowRole]) -> Bool {
        roles.contains { role in
            switch role {
            case .launcherPanel, .hud, .none: false
            case .mainWindow, .sheet, .childWindow, .popover, .openSavePanel, .about, .other: true
            }
        }
    }

    /// The roles of `windows` (the visible ones) that a Dock click could find open. Only windows of the app
    /// count: titled windows (the main window, Settings, About, the welcome screen) and the sheets and child
    /// windows of the main window. Untitled system windows such as the status item's `NSStatusBarWindow` are
    /// always visible and would otherwise make every Dock click find a window.
    static func appWindowRoles(_ windows: [NSWindow], mainWindow: NSWindow?) -> [KeyWindowRole] {
        windows.compactMap { window in
            let role = KeyWindowRole.classify(window, mainWindow: mainWindow)
            switch role {
            case .mainWindow, .sheet, .childWindow, .popover, .openSavePanel, .launcherPanel, .hud: return role
            case .about, .other, .none:
                return window.styleMask.contains(.titled) ? role : nil
            }
        }
    }

    static func apply(showInDock: Bool, to application: NSApplication = .shared) {
        let policy = policy(showInDock: showInDock)
        guard application.activationPolicy() != policy else { return }
        application.setActivationPolicy(policy)
    }
}
