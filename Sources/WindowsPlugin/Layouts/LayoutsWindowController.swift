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

    init(makeModel: @escaping @MainActor () -> LayoutsModel?) {
        self.makeModel = makeModel
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
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = String(localized: "Layouts", comment: "Layouts window title")
        window.setContentSize(NSSize(width: 940, height: 660))
        window.minSize = NSSize(width: 820, height: 540)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("WindowsLayouts")
        self.window = window
        bringForward(window)
    }

    func close() {
        window?.close()
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
