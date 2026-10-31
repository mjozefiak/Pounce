import AppKit
import PounceKit
import SwiftUI
import os

/// Where the panel goes: on the screen with the pointer, horizontally centred in its visible frame (menu
/// bar, notch and Dock excluded), the top edge a quarter of the visible height from the top.
enum PanelGeometry {
    static func frame(height: CGFloat, width: CGFloat, visibleFrame: NSRect) -> NSRect {
        let top = visibleFrame.maxY - visibleFrame.height / 4
        return NSRect(
            x: (visibleFrame.midX - width / 2).rounded(),
            y: (top - height).rounded(),
            width: width,
            height: height
        )
    }

    /// The screen under the pointer, or the main screen.
    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }
}

/// Owns the `LauncherPanel`: Liquid Glass (`NSGlassEffectView`, corner radius 16) as the content view
/// with the SwiftUI content inside, positioning, the 120 ms fade (none with Reduce Motion), resizing to
/// the content, and the window-level keyboard shortcuts.
final class PanelController: NSObject, NSWindowDelegate, PanelPresenting, PanelPresenter {
    let panel: LauncherPanel
    let model: PanelModel
    private weak var field: NSTextField?
    private var observers: [any NSObjectProtocol] = []
    private var fadeGeneration = 0
    private let signposter = OSSignposter(subsystem: "app.pounce", category: "panel")
    let confirmation = ConfirmationHUD()
    private let logger = Logger(subsystem: "app.pounce", category: "panel")

    /// False in QA mode: the panel is ordered front without becoming key, so it never takes keyboard
    /// focus from the tester's app, and losing focus does not close it.
    var takesKeyFocus = true
    var onOpenSettings: () -> Void = {}

    init(model: PanelModel, icons: IconCache, level: LauncherPanel.Level) {
        self.model = model
        self.panel = LauncherPanel(level: level)
        super.init()

        let glass = NSGlassEffectView()
        glass.cornerRadius = 16
        let content = LauncherView(model: model, icons: icons) { [weak self] field in
            self?.field = field
        }
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        glass.contentView = hosting
        panel.contentView = glass
        panel.delegate = self
        panel.keyEquivalentHandler = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }

        model.presenter = self
        model.panelPresenter = self
        observeHeight()

        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.spaceChanged() }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            }
        )
    }

    // MARK: PanelPresenting

    func presentPanel() {
        let state = signposter.beginInterval("show panel")
        let start = ContinuousClock.now
        fadeGeneration += 1
        reposition()
        let animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animates ? 0 : 1
        if takesKeyFocus {
            panel.makeKeyAndOrderFront(nil)
            if let field {
                panel.makeFirstResponder(field)
            }
        } else {
            panel.orderFrontRegardless()
        }
        signposter.endInterval("show panel", state)
        let elapsed = ContinuousClock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        logger.info("Panel ordered front in \(milliseconds, format: .fixed(precision: 2), privacy: .public) ms")
        if animates {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func dismissPanel() {
        fadeGeneration += 1
        let generation = fadeGeneration
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, panel.isVisible else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == generation else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    // MARK: PanelPresenter (for plugin actions)

    func hidePanel() {
        model.hide()
    }

    /// A short message ("Copied") in a small glass bubble where the panel was, also announced.
    func showConfirmation(_ message: LocalizedStringResource) {
        let text = String(localized: message)
        model.announce(text)
        confirmation.show(text, near: panel.frame)
    }

    // MARK: Window events

    func windowDidResignKey(_ notification: Notification) {
        guard takesKeyFocus else { return }
        model.resignedKey()
    }

    private func spaceChanged() {
        guard takesKeyFocus else { return }
        model.hide()
    }

    private func reposition() {
        guard let screen = PanelGeometry.screen(containing: NSEvent.mouseLocation) else { return }
        let frame = PanelGeometry.frame(
            height: model.preferredHeight,
            width: PanelModel.Metrics.width,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrame(frame, display: false)
    }

    /// Resizes to the content, keeping the top edge in place.
    private func observeHeight() {
        withObservationTracking {
            _ = model.preferredHeight
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.resizeToContent()
                self?.observeHeight()
            }
        }
    }

    private func resizeToContent() {
        var frame = panel.frame
        let height = model.preferredHeight
        guard frame.height != height else { return }
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: panel.isVisible)
    }

    // MARK: Keyboard

    /// Command shortcuts: Command-Return (second action), Command-W (clear, then close), Command-,
    /// (Settings), standard text editing (the app has no Edit menu), and any result action's shortcut.
    /// Command-C copies the field's selection when there is one, before any result action sees it.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, panel.isKeyWindow else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let editor = panel.firstResponder as? NSTextView

        // Command-1… pick a list mode's filter.
        if flags == .command, let digit = Int(key), (1...9).contains(digit), model.toggleFilter(at: digit - 1) {
            return true
        }
        if flags == .control, editor?.hasMarkedText() == true {
            return false
        }

        if flags == .command {
            switch key {
            case "\r":
                model.performSecondary()
                return true
            case "w":
                model.escape()
                return true
            case ",":
                onOpenSettings()
                return true
            case "c" where (editor?.selectedRange().length ?? 0) > 0:
                return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            default:
                break
            }
        }

        var modifiers = KeyShortcut.Modifiers()
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if !modifiers.isEmpty, model.perform(shortcut: KeyShortcut(key: key, modifiers: modifiers)) {
            return true
        }

        guard flags == .command || flags == [.command, .shift] else { return false }
        let editing: [String: Selector] = [
            "a": #selector(NSText.selectAll(_:)),
            "c": #selector(NSText.copy(_:)),
            "v": #selector(NSText.paste(_:)),
            "x": #selector(NSText.cut(_:)),
            "z": flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:")),
        ]
        guard let action = editing[key] else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}
