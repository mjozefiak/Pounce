import AppKit
import LintelKit

/// Installs the main menu while the main window (or something it presented) is key and Lintel is the active app,
/// and removes it otherwise, so Command-Q, Command-H and Command-, never fire while the launcher panel has focus
/// and Command-V, Command-Z and Command-A keep working in sheets and panels (spec `2026-11-04-lintel-main-window`,
/// `MainMenu`). The decisions are `MainMenuPolicy`; this class builds the `NSMenu` and watches the key window.
///
/// Installed in every build since step 6.3a removed the release gate of ADR 0008.
final class MainMenuController: NSObject, NSMenuItemValidation {
    private let mainWindow: () -> NSWindow?
    private let mode: () -> MainWindowState.Mode?
    private let section: () -> WorkspaceSection?
    private let openSettings: () -> Void
    private let keyWindow: () -> NSWindow?
    private let setMenu: (NSMenu?) -> Void
    private var observers: [any NSObjectProtocol] = []

    /// Updated from the application's activation notifications; `NSApp.isActive` lags behind them.
    private(set) var isAppActive: Bool
    private(set) var installedMenu: NSMenu?

    init(
        mainWindow: @escaping () -> NSWindow?,
        mode: @escaping () -> MainWindowState.Mode?,
        section: @escaping () -> WorkspaceSection?,
        openSettings: @escaping () -> Void,
        isAppActive: Bool = NSApp?.isActive ?? false,
        keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow },
        setMenu: @escaping (NSMenu?) -> Void = { NSApp.mainMenu = $0 }
    ) {
        self.mainWindow = mainWindow
        self.mode = mode
        self.section = section
        self.openSettings = openSettings
        self.isAppActive = isAppActive
        self.keyWindow = keyWindow
        self.setMenu = setMenu
    }

    /// Stops watching and removes the menu.
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        remove()
    }

    /// Starts watching the key window and the app's activation.
    func start() {
        let center = NotificationCenter.default
        func watch(_ name: Notification.Name, _ handler: @escaping @MainActor (MainMenuController) -> Void) {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if let self { handler(self) } }
                })
        }
        watch(NSApplication.didBecomeActiveNotification) { $0.setAppActive(true) }
        watch(NSApplication.didResignActiveNotification) { $0.setAppActive(false) }
        watch(NSWindow.didBecomeKeyNotification) { $0.refresh() }
        watch(NSWindow.didResignKeyNotification) { $0.refresh() }
        refresh()
    }

    func setAppActive(_ active: Bool) {
        isAppActive = active
        refresh()
    }

    /// Installs or removes the menu for the current key window, mode and section. Also called after the activation
    /// policy changes (`app.showInDock`), which can drop the menu.
    func refresh() {
        let role = isAppActive ? KeyWindowRole.classify(keyWindow(), mainWindow: mainWindow()) : .none
        let current = section()
        let sectionMenu = current.map { section in
            SectionMenu(
                title: String(localized: section.title),
                items: section.menuItems.map {
                    SectionMenu.Item(title: String(localized: $0.title), shortcut: $0.shortcut)
                })
        }
        guard let spec = MainMenuPolicy.menu(for: role, mode: mode() ?? .settings, section: sectionMenu) else {
            remove()
            return
        }
        let menu = Self.build(spec, target: self)
        installedMenu = menu
        setMenu(menu)
    }

    private func remove() {
        guard installedMenu != nil || NSApp?.mainMenu != nil else { return }
        installedMenu = nil
        setMenu(nil)
    }

    // MARK: Actions

    @objc func showSettings(_ sender: Any?) {
        openSettings()
    }

    /// Runs the active section's command at `index`, unless it is disabled or no longer there.
    @discardableResult
    func runSectionCommand(at index: Int) -> Bool {
        guard let items = section()?.menuItems, items.indices.contains(index), items[index].isEnabled() else {
            return false
        }
        items[index].run()
        return true
    }

    @objc private func sectionCommand(_ sender: NSMenuItem) {
        runSectionCommand(at: sender.tag)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(sectionCommand(_:)) else { return true }
        guard let items = section()?.menuItems, items.indices.contains(menuItem.tag) else { return false }
        return items[menuItem.tag].isEnabled()
    }

    // MARK: Building

    static func build(_ spec: MenuSpec, target: MainMenuController) -> NSMenu {
        let main = NSMenu()
        for menu in spec.menus {
            let holder = NSMenuItem()
            let submenu = NSMenu(title: title(of: menu))
            submenu.autoenablesItems = true
            for item in menu.items { submenu.addItem(build(item, target: target)) }
            holder.submenu = submenu
            main.addItem(holder)
        }
        return main
    }

    private static func title(of menu: MenuSpec.Menu) -> String {
        switch menu.kind {
        case .app: "Lintel"
        case .edit: String(localized: "Edit", comment: "Main menu title")
        case .window: String(localized: "Window", comment: "Main menu title")
        case .section: menu.title ?? ""
        }
    }

    private static func build(_ item: MenuSpec.Item, target: MainMenuController) -> NSMenuItem {
        let result: NSMenuItem
        switch item.kind {
        case .separator: return .separator()
        case .settings:
            result = NSMenuItem(
                title: String(localized: "Settings…", comment: "Menu bar menu item that opens Settings"),
                action: #selector(showSettings(_:)), keyEquivalent: "")
            result.target = target
        case .undo: result = responder("Undo", Selector(("undo:")))
        case .redo: result = responder("Redo", Selector(("redo:")))
        case .cut: result = responder("Cut", #selector(NSText.cut(_:)))
        case .copy: result = responder("Copy", #selector(NSText.copy(_:)))
        case .paste: result = responder("Paste", #selector(NSText.paste(_:)))
        case .selectAll: result = responder("Select All", #selector(NSText.selectAll(_:)))
        case .minimize: result = responder("Minimize", #selector(NSWindow.performMiniaturize(_:)))
        case .zoom: result = responder("Zoom", #selector(NSWindow.performZoom(_:)))
        case .sectionCommand(let index):
            result = NSMenuItem(title: item.title ?? "", action: #selector(sectionCommand(_:)), keyEquivalent: "")
            result.target = target
            result.tag = index
        }
        if let shortcut = item.shortcut {
            result.keyEquivalent = shortcut.key
            result.keyEquivalentModifierMask = modifierMask(shortcut.modifiers)
        }
        return result
    }

    /// An item sent up the responder chain (target `nil`), like the system's own Edit menu.
    private static func responder(_ title: String.LocalizationValue, _ action: Selector) -> NSMenuItem {
        NSMenuItem(title: String(localized: title, comment: "Main menu item"), action: action, keyEquivalent: "")
    }

    static func modifierMask(_ modifiers: KeyShortcut.Modifiers) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.control) { mask.insert(.control) }
        return mask
    }
}

extension KeyWindowRole {
    /// The role of `window` relative to the main window. Popovers are child windows, so they classify as such.
    static func classify(_ window: NSWindow?, mainWindow: NSWindow?) -> KeyWindowRole {
        guard let window else { return .none }
        if let mainWindow {
            if window === mainWindow { return .mainWindow }
            if window.sheetParent === mainWindow { return .sheet }
            if window.parent === mainWindow { return .childWindow }
            if window is NSSavePanel, mainWindow.isVisible { return .openSavePanel }
        }
        if window is LauncherPanel { return .launcherPanel }
        if let panel = window as? NSPanel, panel.styleMask.contains(.nonactivatingPanel) { return .hud }
        return .other
    }
}
