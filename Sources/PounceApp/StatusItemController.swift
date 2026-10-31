import AppKit
import Carbon.HIToolbox
import PounceKit

/// What the shell adds to the menu bar menu around the plugins' commands.
struct ShellMenuActions {
    let openPanel: () -> Void
    let openSettings: () -> Void
    let mainShortcut: () -> HotkeyShortcut?
    let runCommand: (PluginCommand) -> Void
}

/// The menu bar item: a template SF Symbol and a menu with "Open Pounce" (showing the current shortcut),
/// the active plugins' commands, Settings, About and Quit. The menu is rebuilt each time it opens, so it
/// always reflects which plugins are active and the current shortcut.
final class StatusItemController: NSObject, NSMenuDelegate {
    static let symbolName = "pawprint.fill"

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let commands: () -> [PluginCommand]
    private let menuBuilder: StatusMenuBuilder

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
            let label = String(localized: "Pounce", comment: "Menu bar item accessibility label")
            let image = NSImage(systemSymbolName: Self.symbolName, accessibilityDescription: label)
            image?.isTemplate = true
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

    /// Opens the menu (QA screenshots).
    func openMenu() {
        statusItem.button?.performClick(nil)
    }

    /// Closes the menu if it is open.
    func closeMenu() {
        menu.cancelTracking()
    }
}

/// Fills the menu bar menu: "Open Pounce", menu commands of active plugins, then Settings, About and
/// Quit, in groups separated by separators.
final class StatusMenuBuilder: NSObject {
    /// Keeps the closure targets of command items alive while the menu shows them.
    private var commandTargets: [CommandTarget] = []
    private let actions: ShellMenuActions?

    init(actions: ShellMenuActions? = nil) {
        self.actions = actions
    }

    func populate(_ menu: NSMenu, commands: [PluginCommand]) {
        menu.removeAllItems()
        commandTargets = []

        if let actions {
            let open = NSMenuItem(
                title: String(localized: "Open Pounce", comment: "Menu bar menu item that opens the panel"),
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
            title: String(localized: "About Pounce", comment: "Menu bar menu item that opens the About window"),
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: String(localized: "Quit Pounce", comment: "Menu bar menu item that quits the app"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
    }

    @objc private func openPanel() {
        actions?.openPanel()
    }

    @objc private func openSettings() {
        actions?.openSettings()
    }

    /// Shows the global shortcut next to "Open Pounce" (display only: the system handles the hotkey).
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
