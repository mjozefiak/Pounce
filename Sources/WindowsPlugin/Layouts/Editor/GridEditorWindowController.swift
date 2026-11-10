import AppKit
import LintelUI
import SwiftUI

/// Opens the grid editor: a modal sheet of the Layouts window when there is one (otherwise a window of its own),
/// with the live preview over the chosen display. One editor at a time; it holds nothing while closed.
@MainActor
final class GridEditorWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var parent: NSWindow?
    private(set) var model: GridEditorModel?
    private var preview: ZoneOverlayPanels?
    /// The app's text size (`app.textSize` through `AppTextSize`), read while the view renders.
    var textSize: () -> TextSize = { AppTextSize.current() }
    var activatesApp = true

    var isOpen: Bool { window != nil }

    /// Shows the editor. `makePreview` and `makeModel` get what the controller owns (the preview, the close
    /// callback), so the model never holds the window.
    func show(
        parent: NSWindow?,
        makeModel: @MainActor (_ preview: ZoneOverlayPanels, _ close: @escaping () -> Void) -> GridEditorModel
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let preview = ZoneOverlayPanels()
        let model = makeModel(preview) { [weak self] in self?.finish() }
        self.preview = preview
        self.model = model
        self.parent = parent
        let view = LintelTextSizeScope(size: textSize) { GridEditorView(model: model) }
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = String(localized: "Layout Editor", comment: "Layout editor window title")
        window.setContentSize(NSSize(width: 960, height: 640))
        window.minSize = NSSize(width: 880, height: 580)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.tabbingMode = .disallowed
        self.window = window
        if let parent, parent.isVisible {
            parent.beginSheet(window)
        } else {
            window.center()
            if activatesApp {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }
        }
    }

    /// The plugin was switched off: the editor closes after asking about unsaved changes.
    func pluginSwitchedOff() { model?.pluginSwitchedOff() }

    /// Closes at once, without asking (the model already did).
    private func finish() {
        guard let window else { return }
        model?.tearDown()
        preview?.tearDown()
        if let parent, window.sheetParent === parent {
            parent.endSheet(window)
        }
        window.orderOut(nil)
        window.contentViewController = nil
        self.window = nil
        model = nil
        preview = nil
        parent = nil
    }

    /// The close button asks the same question as Cancel, so a click never loses changes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model?.cancel()
        return false
    }
}
