import AppKit
import PounceKit

/// The menu bar item: a template SF Symbol and a menu with the active plugins' commands, About and
/// Quit. The menu is rebuilt each time it opens, so it always reflects which plugins are active.
final class StatusItemController: NSObject, NSMenuDelegate {
    static let symbolName = "pawprint.fill"

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let commands: () -> [PluginCommand]
    private let menuBuilder = StatusMenuBuilder()

    init(statusBar: NSStatusBar = .system, commands: @escaping () -> [PluginCommand]) {
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        self.commands = commands
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

/// Fills the menu bar menu: menu commands of active plugins, then About and Quit, separated.
final class StatusMenuBuilder: NSObject {
    /// Keeps the closure targets of command items alive while the menu shows them.
    private var commandTargets: [CommandTarget] = []

    func populate(_ menu: NSMenu, commands: [PluginCommand]) {
        menu.removeAllItems()
        commandTargets = []

        let menuCommands = commands.filter(\.showsInMenu)
        for command in menuCommands {
            let target = CommandTarget(command: command)
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
        if !menuCommands.isEmpty {
            menu.addItem(.separator())
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

    @objc private func showAbout() {
        // An agent app is never active on its own; activate so the panel comes to the front.
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}

/// Bridges a `PluginCommand` closure to an AppKit target/action pair.
final class CommandTarget: NSObject {
    let command: PluginCommand

    init(command: PluginCommand) {
        self.command = command
    }

    @objc func runCommand() {
        let run = command.run
        Task { await run() }
    }
}
