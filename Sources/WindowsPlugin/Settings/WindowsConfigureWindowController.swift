import AppKit
import LintelUI
import SwiftUI

/// Opens the Configure window (window management v2, Phase 2): one plugin-owned window, reused, built on first use
/// and rebuilt after it was closed, so it never shows stale values and holds nothing while it is closed.
@MainActor
final class WindowsConfigureWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let makeModel: @MainActor () -> WindowsConfigureModel?
    private(set) var model: WindowsConfigureModel?
    var textSize: () -> TextSize = { AppTextSize.current() }
    /// False in QA mode: the window is ordered front without activating Lintel.
    var activatesApp = true

    static let defaultSize = NSSize(width: 760, height: 520)
    static let minimumSize = NSSize(width: 640, height: 420)

    init(makeModel: @escaping @MainActor () -> WindowsConfigureModel?) {
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
        let controller = NSHostingController(
            rootView: LintelTextSizeScope(size: textSize) { WindowsConfigureView(model: model) })
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = String(localized: "Configure Window Management", comment: "Configure window title")
        window.minSize = Self.minimumSize
        window.setContentSize(Self.defaultSize)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.tabbingMode = .disallowed
        window.center()
        self.window = window
        bringForward(window)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
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
