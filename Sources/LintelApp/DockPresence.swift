import AppKit

/// Lintel is a menu bar app (`LSUIElement`), and by default it also has an icon in the Dock: the activation
/// policy is switched at runtime from the `app.showInDock` setting.
enum DockPresence {
    static func policy(showInDock: Bool) -> NSApplication.ActivationPolicy {
        showInDock ? .regular : .accessory
    }

    static func apply(showInDock: Bool, to application: NSApplication = .shared) {
        let policy = policy(showInDock: showInDock)
        guard application.activationPolicy() != policy else { return }
        application.setActivationPolicy(policy)
    }
}
