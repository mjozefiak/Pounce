import LintelKit

/// What the key window is, as far as the main menu cares (spec `2026-11-04-lintel-main-window`, `MainMenu`).
enum KeyWindowRole: Equatable, CaseIterable {
    /// The main window itself.
    case mainWindow
    /// A sheet attached to the main window (`ConfirmSheet`, a save sheet).
    case sheet
    /// A child window of the main window.
    case childWindow
    /// A popover of the main window.
    case popover
    /// An open or save panel the main window presented.
    case openSavePanel
    case launcherPanel
    case hud
    case about
    /// Any other window (Settings, the welcome screen).
    case other
    /// No key window.
    case none
}

/// A section menu: the title of the active workspace section and its items, already resolved to text.
struct SectionMenu: Equatable {
    struct Item: Equatable {
        var title: String
        var shortcut: KeyShortcut?
    }

    var title: String
    var items: [Item]
}

/// The main menu as data. Titles of the fixed menus are localized by `MainMenuController`; only section texts
/// are carried here.
struct MenuSpec: Equatable {
    enum MenuKind: Equatable {
        case app, edit, section, window
    }

    enum ItemKind: Equatable {
        case settings, undo, redo, cut, copy, paste, selectAll, minimize, zoom
        case sectionCommand(Int)
        case separator
    }

    struct Item: Equatable {
        var kind: ItemKind
        var title: String?
        var shortcut: KeyShortcut?
    }

    struct Menu: Equatable {
        var kind: MenuKind
        var title: String?
        var items: [Item]
    }

    var menus: [Menu]
}

/// Decides which menu exists for the key window. Pure.
///
/// There is deliberately no Quit, Hide or Close item: Command-Q and Command-H must not fire while the launcher
/// panel has focus, and `ShellWindow` handles Command-W itself, so a Close item would fire it twice.
enum MainMenuPolicy {
    /// `nil` when no menu may be installed for the role.
    ///
    /// - Parameters:
    ///   - mode: the main window's mode; the section menu exists in Workspace mode only.
    ///   - section: the active section's menu.
    static func menu(
        for keyWindowRole: KeyWindowRole, mode: MainWindowState.Mode = .workspace, section: SectionMenu? = nil
    ) -> MenuSpec? {
        switch keyWindowRole {
        case .mainWindow, .sheet, .childWindow, .popover, .openSavePanel: break
        case .launcherPanel, .hud, .about, .other, .none: return nil
        }
        let command = KeyShortcut.Modifiers.command
        func item(_ kind: MenuSpec.ItemKind, _ key: String? = nil, _ modifiers: KeyShortcut.Modifiers = command)
            -> MenuSpec.Item
        {
            MenuSpec.Item(kind: kind, title: nil, shortcut: key.map { KeyShortcut(key: $0, modifiers: modifiers) })
        }
        let separator = MenuSpec.Item(kind: .separator, title: nil, shortcut: nil)

        var menus = [
            MenuSpec.Menu(kind: .app, title: nil, items: [item(.settings, ",")]),
            MenuSpec.Menu(
                kind: .edit, title: nil,
                items: [
                    item(.undo, "z"), item(.redo, "z", [.command, .shift]), separator,
                    item(.cut, "x"), item(.copy, "c"), item(.paste, "v"), item(.selectAll, "a"),
                ]),
        ]
        if mode == .workspace, let section, !section.items.isEmpty {
            let items = section.items.enumerated().map {
                MenuSpec.Item(kind: .sectionCommand($0.offset), title: $0.element.title, shortcut: $0.element.shortcut)
            }
            menus.insert(MenuSpec.Menu(kind: .section, title: section.title, items: items), at: 1)
        }
        menus.append(MenuSpec.Menu(kind: .window, title: nil, items: [item(.minimize, "m"), item(.zoom)]))
        return MenuSpec(menus: menus)
    }
}
