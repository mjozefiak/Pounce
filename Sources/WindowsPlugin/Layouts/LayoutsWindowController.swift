import AppKit
import LintelUI
import SwiftUI

/// Opens the Layouts window: one window, reused. Created by the plugin and used only by the *Layouts…* row of the
/// settings pane; nothing opens it by itself, and it holds no state while it is closed.
@MainActor
final class LayoutsWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    /// `nil` when the plugin that owns the model is gone.
    private let makeModel: @MainActor () -> LayoutsModel?
    /// The model of the open window, `nil` while it is closed.
    private(set) var model: LayoutsModel?
    /// The app's text size (`app.textSize` through `AppTextSize`), read while the view renders.
    var textSize: () -> TextSize = { AppTextSize.current() }
    /// False in QA mode: the window is ordered front without activating Lintel.
    var activatesApp = true

    /// Where the window's frame is remembered: the plugin's settings (`WindowsSettings.layoutsWindowFrame`), never
    /// the window system's own autosave, which writes to the real defaults domain even in a QA run.
    private let loadFrame: () -> String?
    private let saveFrame: (String) -> Void

    static let defaultSize = NSSize(width: 980, height: 680)
    static let minimumSize = NSSize(width: 900, height: 560)

    init(
        makeModel: @escaping @MainActor () -> LayoutsModel?, loadFrame: @escaping () -> String? = { nil },
        saveFrame: @escaping (String) -> Void = { _ in }
    ) {
        self.makeModel = makeModel
        self.loadFrame = loadFrame
        self.saveFrame = saveFrame
    }

    var isOpen: Bool { window?.isVisible ?? false }

    func show() {
        if let window {
            bringForward(window)
            return
        }
        guard let model = makeModel() else { return }
        self.model = model
        let view = LintelTextSizeScope(size: textSize) { LayoutsWindowView(model: model) }
        let controller = NSHostingController(rootView: view)
        // The window has its own size: the view's ideal size must not stretch it (it opened 1265 by 1362).
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = String(localized: "Layouts", comment: "Layouts window title")
        window.minSize = Self.minimumSize
        window.setContentSize(Self.defaultSize)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        window.center()
        if let stored = loadFrame(), let frame = Self.usableFrame(stored, screens: NSScreen.screens.map(\.visibleFrame))
        {
            window.setFrame(frame, display: false)
        }
        self.window = window
        bringForward(window)
    }

    func close() {
        window?.close()
    }

    /// A remembered frame made usable: parsed, at least the minimum size, at most the size of a screen, and on a screen
    /// (`nil` when it cannot be read or lies on no connected screen).
    static func usableFrame(_ stored: String, screens: [CGRect]) -> NSRect? {
        let frame = NSRectFromString(stored)
        guard frame.width > 0, frame.height > 0, let screen = screens.first(where: { $0.intersects(frame) }) else {
            return nil
        }
        var usable = frame
        usable.size.width = min(max(frame.width, minimumSize.width), screen.width)
        usable.size.height = min(max(frame.height, minimumSize.height), screen.height)
        usable.origin.x = min(max(usable.origin.x, screen.minX), screen.maxX - usable.width)
        usable.origin.y = min(max(usable.origin.y, screen.minY), screen.maxY - usable.height)
        return usable
    }

    func windowDidResize(_ notification: Notification) { remember() }
    func windowDidMove(_ notification: Notification) { remember() }

    private func remember() {
        guard let window, window.isVisible else { return }
        saveFrame(NSStringFromRect(window.frame))
    }

    func windowWillClose(_ notification: Notification) {
        // The window and its model are rebuilt on the next open, so nothing stale is shown.
        window?.contentViewController = nil
        window = nil
        model = nil
    }

    private func bringForward(_ window: NSWindow) {
        if activatesApp {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }
}
