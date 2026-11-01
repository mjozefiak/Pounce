import AppKit
import SwiftUI

/// The single Settings window: a toolbar-style tab view with General, Features, every active plugin's
/// own pane, Permissions and Advanced (Phase 4), each a SwiftUI `Form`.
///
/// Spec deviation: an AppKit window rather than a SwiftUI `Settings` scene. Pounce runs from an
/// `NSApplicationDelegate` as a menu bar agent, and since macOS 14 a `Settings` scene can only be opened
/// from inside SwiftUI views (`showSettingsWindow:` no longer works from AppKit). The window looks and
/// behaves the same: toolbar tabs with SF Symbols, grouped forms, 600 pt wide.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    enum Pane: String, CaseIterable {
        case general
        case features
        case permissions
        case advanced
    }

    /// The shell panes before the plugins' panes; the others come after them.
    static let leadingPanes: [Pane] = [.general, .features]

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
    private let makePermissions: () -> AnyView
    private let makeAdvanced: () -> AnyView
    private let pluginPanes: () -> [PluginPane]

    /// False in QA mode: the window is ordered front without activating Pounce.
    var activatesApp = true

    init(
        general: @escaping () -> AnyView,
        features: @escaping () -> AnyView,
        permissions: @escaping () -> AnyView = { AnyView(EmptyView()) },
        advanced: @escaping () -> AnyView = { AnyView(EmptyView()) },
        pluginPanes: @escaping () -> [PluginPane]
    ) {
        self.makeGeneral = general
        self.makeFeatures = features
        self.makePermissions = permissions
        self.makeAdvanced = advanced
        self.pluginPanes = pluginPanes
    }

    /// The tab index of a shell pane: General and Features first, then the plugins' panes, then
    /// Permissions and Advanced.
    static func tabIndex(of pane: Pane, pluginPaneCount: Int) -> Int {
        switch pane {
        case .general: 0
        case .features: 1
        case .permissions: leadingPanes.count + pluginPaneCount
        case .advanced: leadingPanes.count + pluginPaneCount + 1
        }
    }

    /// The tab index of a plugin's pane, or `nil` when the plugin has none.
    static func tabIndex(ofPlugin id: String, in pluginPaneIDs: [String]) -> Int? {
        pluginPaneIDs.firstIndex(of: id).map { leadingPanes.count + $0 }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(_ pane: Pane = .general) {
        rebuildIfNeeded()
        tabs?.selectedTabViewItemIndex = Self.tabIndex(of: pane, pluginPaneCount: pluginPaneIDs.count)
        present()
    }

    /// Opens a plugin's own pane (by plugin id), or General when the plugin has none.
    func showPluginPane(_ id: String) {
        rebuildIfNeeded()
        tabs?.selectedTabViewItemIndex = Self.tabIndex(ofPlugin: id, in: pluginPaneIDs) ?? 0
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
        addTab(
            to: tabs,
            title: String(localized: "Permissions", comment: "Settings pane title"),
            symbol: "hand.raised",
            view: makePermissions()
        )
        addTab(
            to: tabs,
            title: String(localized: "Advanced", comment: "Settings pane title"),
            symbol: "gearshape.2",
            view: makeAdvanced()
        )

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
