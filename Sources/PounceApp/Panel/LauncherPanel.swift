import AppKit

/// The launcher window: a borderless, non-activating floating panel built once at launch and only
/// shown or hidden afterwards (spec: UI/UX → Panel).
///
/// `.nonactivatingPanel` is passed to `init`: changing it later does not update the window server.
/// Showing it never activates Pounce, so the previous app stays frontmost. It joins every Space and
/// shows over full-screen apps (`.fullScreenAuxiliary`); spike 1.2's fallback raises the level to
/// `.statusBar` through `app.panelLevel`.
final class LauncherPanel: NSPanel {
    enum Level: String {
        case floating
        case statusBar

        var windowLevel: NSWindow.Level {
            switch self {
            case .floating: .floating
            case .statusBar: .statusBar
            }
        }
    }

    /// Key equivalents (Command shortcuts) go here before the field editor sees them. Returns whether the
    /// event was handled.
    var keyEquivalentHandler: ((NSEvent) -> Bool)?

    init(level: Level) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: PanelModel.Metrics.width, height: PanelModel.Metrics.fieldHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        self.level = level.windowLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        setAccessibilityLabel(String(localized: "Pounce", comment: "Menu bar item accessibility label"))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyEquivalentHandler?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
