import AppKit
import Carbon.HIToolbox
import LintelKit

/// What the shell adds to the menu bar menu around the plugins' commands.
struct ShellMenuActions {
    let openPanel: () -> Void
    let openSettings: () -> Void
    let mainShortcut: () -> HotkeyShortcut?
    let runCommand: (PluginCommand) -> Void
    /// A plugin command's current global shortcut, shown next to its menu item. Added in Phase 2.
    var commandShortcut: (String) -> HotkeyShortcut? = { _ in nil }
    /// Opens Lintel's About window. Added in Phase 4; without it the standard About panel opens.
    var showAbout: (() -> Void)?
    /// The version a background update check found and the user has not looked at yet (spec
    /// `2026-11-19-updates-and-open-source-hygiene`, Step 4.4); `nil` hides the menu item.
    var pendingUpdate: () -> String? = { nil }
    /// Shows the found update (the update framework's own window).
    var showUpdate: (() -> Void)?
    /// Whether "Check for Updates…" can run now (false when the updater is off or a check is running).
    var canCheckForUpdates: () -> Bool = { false }
    /// A check the user asked for. `nil` leaves the menu item out.
    var checkForUpdates: (() -> Void)?
}

/// The menu bar item: a template SF Symbol and a menu with "Open Lintel" (showing the current shortcut),
/// the active plugins' commands, Settings, About and Quit. The menu is rebuilt each time it opens, so it
/// always reflects which plugins are active and the current shortcut.
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let commands: () -> [PluginCommand]
    private let menuBuilder: StatusMenuBuilder
    private var updateBadge: UpdateBadgeView?

    init(
        statusBar: NSStatusBar = .system,
        actions: ShellMenuActions? = nil,
        commands: @escaping () -> [PluginCommand]
    ) {
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        self.commands = commands
        self.menuBuilder = StatusMenuBuilder(actions: actions)
        super.init()
        if let button = statusItem.button {
            let label = String(localized: "Lintel", comment: "Menu bar item accessibility label")
            let image = LintelMark.menuBarImage()
            image.accessibilityDescription = label
            button.image = image
            button.setAccessibilityLabel(label)
        }
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func rebuildMenu() {
        menuBuilder.populate(menu, commands: commands())
    }

    /// Shows or hides the dot that says a background check found an update. Nothing else announces it: no
    /// window, no notification (spec Step 4.4).
    func setUpdateBadge(_ visible: Bool) {
        guard let button = statusItem.button else { return }
        let label =
            visible
            ? String(localized: "Lintel, update available", comment: "Menu bar item accessibility label with an update")
            : String(localized: "Lintel", comment: "Menu bar item accessibility label")
        button.setAccessibilityLabel(label)
        if visible, updateBadge == nil {
            // The status bar button is a flipped view: its top edge is minY.
            let badge = UpdateBadgeView(frame: UpdateBadgeView.frame(in: button.bounds, flipped: button.isFlipped))
            badge.autoresizingMask = UpdateBadgeView.autoresizingMask(flipped: button.isFlipped)
            button.addSubview(badge)
            updateBadge = badge
        } else if !visible {
            updateBadge?.removeFromSuperview()
            updateBadge = nil
        }
    }

    /// Whether the update dot is shown (tests).
    var showsUpdateBadge: Bool { updateBadge != nil }

    /// Opens the menu (QA screenshots).
    func openMenu() {
        statusItem.button?.performClick(nil)
    }

    /// Closes the menu if it is open.
    func closeMenu() {
        menu.cancelTracking()
    }
}

/// Fills the menu bar menu: "Open Lintel", menu commands of active plugins, then Settings, About and
/// Quit, in groups separated by separators.
final class StatusMenuBuilder: NSObject, NSMenuItemValidation {
    /// Keeps the closure targets of command items alive while the menu shows them.
    private var commandTargets: [CommandTarget] = []
    private let actions: ShellMenuActions?

    init(actions: ShellMenuActions? = nil) {
        self.actions = actions
    }

    func populate(_ menu: NSMenu, commands: [PluginCommand]) {
        menu.removeAllItems()
        commandTargets = []

        if let actions, let version = actions.pendingUpdate() {
            let update = NSMenuItem(
                title: String(
                    localized: "Update Available: \(version)…",
                    comment: "Menu bar menu item shown when a newer version was found; opens the update window"),
                action: #selector(showUpdate),
                keyEquivalent: ""
            )
            update.target = self
            update.identifier = Self.updateItemIdentifier
            menu.addItem(update)
            menu.addItem(.separator())
        }

        if let actions {
            let open = NSMenuItem(
                title: String(localized: "Open Lintel", comment: "Menu bar menu item that opens the panel"),
                action: #selector(openPanel),
                keyEquivalent: ""
            )
            open.target = self
            if let shortcut = actions.mainShortcut() {
                Self.applyShortcut(shortcut, to: open)
            }
            menu.addItem(open)
        }

        let menuCommands = commands.filter(\.showsInMenu)
        for command in menuCommands {
            let target = CommandTarget(command: command, run: actions?.runCommand)
            commandTargets.append(target)
            let item = NSMenuItem(
                title: String(localized: command.title),
                action: #selector(CommandTarget.runCommand),
                keyEquivalent: ""
            )
            item.target = target
            if let symbolName = command.symbolName {
                item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            }
            if let shortcut = actions?.commandShortcut(command.id) {
                Self.applyShortcut(shortcut, to: item)
            }
            menu.addItem(item)
        }
        if !menuCommands.isEmpty || actions != nil {
            menu.addItem(.separator())
        }

        if actions != nil {
            let settings = NSMenuItem(
                title: String(localized: "Settings…", comment: "Menu bar menu item that opens Settings"),
                action: #selector(openSettings),
                keyEquivalent: ","
            )
            settings.keyEquivalentModifierMask = .command
            settings.target = self
            menu.addItem(settings)
        }

        let about = NSMenuItem(
            title: String(localized: "About Lintel", comment: "Menu bar menu item that opens the About window"),
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        if actions?.checkForUpdates != nil {
            let check = NSMenuItem(
                title: String(
                    localized: "Check for Updates…",
                    comment: "Menu bar menu item that asks the update framework to check for a new version"),
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            )
            check.target = self
            check.identifier = Self.checkItemIdentifier
            menu.addItem(check)
        }
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: String(localized: "Quit Lintel", comment: "Menu bar menu item that quits the app"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
    }

    static let updateItemIdentifier = NSUserInterfaceItemIdentifier("lintel.menu.update")
    static let checkItemIdentifier = NSUserInterfaceItemIdentifier("lintel.menu.checkForUpdates")

    /// "Check for Updates…" is dimmed while the updater is off or a check is running.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.identifier == Self.checkItemIdentifier { return actions?.canCheckForUpdates() ?? false }
        return true
    }

    @objc private func checkForUpdates() {
        actions?.checkForUpdates?()
    }

    @objc private func showUpdate() {
        actions?.showUpdate?()
    }

    @objc private func openPanel() {
        actions?.openPanel()
    }

    @objc private func openSettings() {
        actions?.openSettings()
    }

    /// Shows the global shortcut next to "Open Lintel" (display only: the system handles the hotkey).
    static func applyShortcut(_ shortcut: HotkeyShortcut, to item: NSMenuItem) {
        let key =
            shortcut.carbonKeyCode == kVK_Space ? " " : HotkeyShortcut.keyNames[shortcut.carbonKeyCode]?.lowercased()
        guard let key, key.count == 1 else { return }
        item.keyEquivalent = key
        var mask: NSEvent.ModifierFlags = []
        if shortcut.carbonModifiers & cmdKey != 0 { mask.insert(.command) }
        if shortcut.carbonModifiers & controlKey != 0 { mask.insert(.control) }
        if shortcut.carbonModifiers & optionKey != 0 { mask.insert(.option) }
        if shortcut.carbonModifiers & shiftKey != 0 { mask.insert(.shift) }
        item.keyEquivalentModifierMask = mask
    }

    @objc private func showAbout() {
        if let showAbout = actions?.showAbout {
            showAbout()
            return
        }
        // An agent app is never active on its own; activate so the panel comes to the front.
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}

/// Bridges a `PluginCommand` closure to an AppKit target/action pair.
final class CommandTarget: NSObject {
    let command: PluginCommand
    private let run: ((PluginCommand) -> Void)?

    init(command: PluginCommand, run: ((PluginCommand) -> Void)? = nil) {
        self.command = command
        self.run = run
    }

    @objc func runCommand() {
        if let run {
            run(command)
            return
        }
        let action = command.run
        Task { await action() }
    }
}

/// The dot on the menu bar item while an update waits: the accent colour, in the top right corner.
final class UpdateBadgeView: NSView {
    static let diameter: CGFloat = 6

    /// The dot's frame in the top right corner of `bounds`, in the coordinates of a flipped (top edge at minY) or an
    /// unflipped superview.
    static func frame(in bounds: NSRect, flipped: Bool) -> NSRect {
        let y = flipped ? bounds.minY + 4 : bounds.maxY - diameter - 4
        return NSRect(x: bounds.maxX - diameter - 3, y: y, width: diameter, height: diameter)
    }

    /// Keeps the dot at the top right corner when the button resizes: the left margin and the bottom margin stretch.
    static func autoresizingMask(flipped: Bool) -> NSView.AutoresizingMask {
        [.minXMargin, flipped ? .maxYMargin : .minYMargin]
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
