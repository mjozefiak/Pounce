import AppKit
import SwiftUI

/// The single Settings window: a toolbar-style tab view with General, Features and every active plugin's
/// own pane, each a SwiftUI `Form`.
///
/// Spec deviation: an AppKit window rather than a SwiftUI `Settings` scene. Pounce runs from an
/// `NSApplicationDelegate` as a menu bar agent, and since macOS 14 a `Settings` scene can only be opened
/// from inside SwiftUI views (`showSettingsWindow:` no longer works from AppKit). The window looks and
/// behaves the same: toolbar tabs with SF Symbols, grouped forms, 600 pt wide.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    enum Pane: String, CaseIterable {
        case general
        case features
    }

    struct PluginPane {
        let id: String
        let title: String
        let symbolName: String
        let view: AnyView
    }

    private var window: NSWindow?
    private var tabs: NSTabViewController?
    private var pluginPaneIDs: [String] = []
    private let makeGeneral: () -> AnyView
    private let makeFeatures: () -> AnyView
    private let pluginPanes: () -> [PluginPane]

    /// False in QA mode: the window is ordered front without activating Pounce.
    var activatesApp = true

    init(
        general: @escaping () -> AnyView,
        features: @escaping () -> AnyView,
        pluginPanes: @escaping () -> [PluginPane]
    ) {
        self.makeGeneral = general
        self.makeFeatures = features
        self.pluginPanes = pluginPanes
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(_ pane: Pane = .general) {
        rebuildIfNeeded()
        tabs?.selectedTabViewItemIndex = Pane.allCases.firstIndex(of: pane) ?? 0
        present()
    }

    /// Opens a plugin's own pane (by plugin id), or General when the plugin has none.
    func showPluginPane(_ id: String) {
        rebuildIfNeeded()
        let index = pluginPaneIDs.firstIndex(of: id).map { Pane.allCases.count + $0 } ?? 0
        tabs?.selectedTabViewItemIndex = index
        present()
    }

    private func rebuildIfNeeded() {
        let plugins = pluginPanes()
        if window == nil || plugins.map(\.id) != pluginPaneIDs {
            build(plugins)
        }
    }

    private func present() {
        guard let window else { return }
        if activatesApp {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    func close() {
        window?.close()
    }

    private func build(_ plugins: [PluginPane]) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        addTab(
            to: tabs,
            title: String(localized: "General", comment: "Settings pane title"),
            symbol: "gearshape",
            view: makeGeneral()
        )
        addTab(
            to: tabs,
            title: String(localized: "Features", comment: "Settings pane title"),
            symbol: "puzzlepiece.extension",
            view: makeFeatures()
        )
        for pane in plugins {
            addTab(to: tabs, title: pane.title, symbol: pane.symbolName, view: pane.view)
        }

        let frame = window?.frame
        window?.close()
        let window = ShellWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.delegate = self
        if let frame {
            window.setFrameTopLeftPoint(NSPoint(x: frame.minX, y: frame.maxY))
        } else {
            window.center()
        }
        self.window = window
        self.tabs = tabs
        pluginPaneIDs = plugins.map(\.id)
    }

    private func addTab(to tabs: NSTabViewController, title: String, symbol: String, view: AnyView) {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }
}
