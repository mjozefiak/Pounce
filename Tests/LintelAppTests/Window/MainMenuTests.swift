import AppKit
import LintelKit
import SwiftUI
import Testing

@testable import LintelApp

/// Spec `2026-11-04-lintel-main-window`, step 1.4: the main menu's policy, its installation and Command-W.
@MainActor @Suite struct MainMenuTests {
    private let cmd = KeyShortcut.Modifiers.command

    private func section(
        items: [SectionMenu.Item] = [.init(title: "New Note", shortcut: KeyShortcut(key: "n", modifiers: .command))]
    )
        -> SectionMenu
    {
        SectionMenu(title: "Notes", items: items)
    }

    private func summary(_ spec: MenuSpec) -> [String] {
        spec.menus.flatMap { menu in
            menu.items.map { item in
                let key = item.shortcut.map { "\($0.modifiers.rawValue)+\($0.key)" } ?? "-"
                return "\(menu.kind)/\(item.kind)/\(item.title ?? "")/\(key)"
            }
        }
    }

    @Test func rolesThatGetTheMenu() {
        for role in [KeyWindowRole.mainWindow, .sheet, .childWindow, .popover, .openSavePanel] {
            #expect(MainMenuPolicy.menu(for: role) != nil, "\(role)")
        }
    }

    @Test func rolesWithoutAMenu() {
        for role in [KeyWindowRole.launcherPanel, .hud, .about, .other, .none] {
            #expect(MainMenuPolicy.menu(for: role, section: section()) == nil, "\(role)")
        }
    }

    @Test func workspaceModeMenuHasExactItemsAndKeys() throws {
        let spec = try #require(MainMenuPolicy.menu(for: .mainWindow, mode: .workspace, section: section()))
        #expect(spec.menus.map(\.kind) == [.app, .section, .edit, .window])
        #expect(spec.menus[1].title == "Notes")
        #expect(
            summary(spec) == [
                "app/settings//\(cmd.rawValue)+,",
                "section/sectionCommand(0)/New Note/\(cmd.rawValue)+n",
                "edit/undo//\(cmd.rawValue)+z",
                "edit/redo//\((cmd.union(.shift)).rawValue)+z",
                "edit/separator//-",
                "edit/cut//\(cmd.rawValue)+x",
                "edit/copy//\(cmd.rawValue)+c",
                "edit/paste//\(cmd.rawValue)+v",
                "edit/selectAll//\(cmd.rawValue)+a",
                "window/minimize//\(cmd.rawValue)+m",
                "window/zoom//-",
            ])
    }

    @Test func settingsModeHasNoSectionMenu() throws {
        let spec = try #require(MainMenuPolicy.menu(for: .mainWindow, mode: .settings, section: section()))
        #expect(spec.menus.map(\.kind) == [.app, .edit, .window])
    }

    @Test func aSectionWithoutItemsHasNoMenu() throws {
        let spec = try #require(MainMenuPolicy.menu(for: .sheet, section: section(items: [])))
        #expect(spec.menus.map(\.kind) == [.app, .edit, .window])
    }

    @Test func thereIsNoQuitHideOrCloseItem() throws {
        let spec = try #require(MainMenuPolicy.menu(for: .mainWindow, section: section()))
        let menu = MainMenuController.build(spec, target: makeController().0)
        let titles = menu.items.compactMap(\.submenu).flatMap(\.items).map { $0.title.lowercased() }
        for word in ["quit", "hide", "close"] { #expect(!titles.contains { $0.contains(word) }) }
        for key in ["q", "h", "w"] {
            let keys = menu.items.compactMap(\.submenu).flatMap(\.items)
                .filter { $0.keyEquivalentModifierMask == .command }.map(\.keyEquivalent)
            #expect(!keys.contains(key))
        }
    }

    // MARK: Classification

    @Test func classifiesWindows() {
        let main = NSWindow()
        let other = NSWindow()
        let child = NSWindow()
        main.addChildWindow(child, ordered: .above)
        let hud = NSPanel(
            contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: true)
        #expect(KeyWindowRole.classify(nil, mainWindow: main) == .none)
        #expect(KeyWindowRole.classify(main, mainWindow: main) == .mainWindow)
        #expect(KeyWindowRole.classify(child, mainWindow: main) == .childWindow)
        #expect(KeyWindowRole.classify(other, mainWindow: main) == .other)
        #expect(KeyWindowRole.classify(hud, mainWindow: main) == .hud)
        #expect(KeyWindowRole.classify(main, mainWindow: nil) == .other)
    }

    // MARK: Installation

    private final class Recorder {
        var key: NSWindow?
        var menus: [NSMenu?] = []
        var mode: MainWindowState.Mode? = .workspace
        var settingsOpened = 0
        var section: WorkspaceSection?
    }

    private func makeController(isAppActive: Bool = true) -> (MainMenuController, Recorder, NSWindow) {
        let recorder = Recorder()
        let main = NSWindow()
        let controller = MainMenuController(
            mainWindow: { main }, mode: { recorder.mode }, section: { recorder.section },
            openSettings: { recorder.settingsOpened += 1 }, isAppActive: isAppActive,
            keyWindow: { recorder.key }, setMenu: { recorder.menus.append($0) })
        return (controller, recorder, main)
    }

    @Test func installsForTheMainWindowAndRemovesOtherwise() {
        let (controller, recorder, main) = makeController()
        recorder.key = main
        controller.refresh()
        #expect(controller.installedMenu != nil)
        recorder.key = NSWindow()
        controller.refresh()
        #expect(controller.installedMenu == nil)
        #expect(recorder.menus.last! == nil)
    }

    @Test func removedWhenTheAppResignsActive() {
        let (controller, recorder, main) = makeController()
        recorder.key = main
        controller.refresh()
        controller.setAppActive(false)
        #expect(controller.installedMenu == nil)
        controller.setAppActive(true)
        #expect(controller.installedMenu != nil)
    }

    @Test func settingsItemOpensSettingsAndSectionCommandsAreValidated() throws {
        let (controller, recorder, main) = makeController()
        var ran = 0
        var enabled = false
        recorder.section = WorkspaceSection(
            id: "notes", title: "Notes", symbolName: "note", order: 0, makeView: { AnyView(EmptyView()) },
            menuItems: [CommandInfo(title: "New Note", isEnabled: { enabled }, run: { ran += 1 })])
        recorder.key = main
        controller.refresh()
        let menu = try #require(controller.installedMenu)
        let settings = try #require(menu.items[0].submenu?.items.first)
        _ = settings.target?.perform(settings.action, with: settings)
        #expect(recorder.settingsOpened == 1)

        let command = try #require(menu.items[1].submenu?.items.first)
        #expect(!controller.validateMenuItem(command))
        #expect(!controller.runSectionCommand(at: 0))
        #expect(ran == 0)
        enabled = true
        #expect(controller.validateMenuItem(command))
        #expect(controller.runSectionCommand(at: 0))
        #expect(ran == 1)
        #expect(!controller.runSectionCommand(at: 5))
    }

    // MARK: Command-W

    private func controllerWithSection(
        handleClose: @escaping @MainActor @Sendable () -> Bool,
        willHide: @escaping @MainActor @Sendable () async -> Void
    ) -> MainWindowController {
        let section = WorkspaceSection(
            id: "notes", title: "Notes", symbolName: "note", order: 0, makeView: { AnyView(EmptyView()) },
            willHide: willHide, handleClose: handleClose)
        let controller = MainWindowController(
            settings: InMemorySettingsStore(), sections: { [section] }, settingsPanes: { ["general"] },
            frameAutosaveName: nil, makeContent: { _, _ in AnyView(EmptyView()) })
        controller.activatesApp = false
        controller.showWorkspace()
        return controller
    }

    @Test func aSectionThatHandlesCloseKeepsTheWindowOpen() {
        var closes = 0
        var hides = 0
        let controller = controllerWithSection(
            handleClose: {
                closes += 1
                return true
            }, willHide: { hides += 1 })
        #expect(controller.requestClose() == nil)
        #expect(closes == 1)
        #expect(hides == 0)
        controller.close()
    }

    @Test func closeAsksTheSectionOnceThenHidesAndCloses() async throws {
        var closes = 0
        var hides = 0
        let controller = controllerWithSection(
            handleClose: {
                closes += 1
                return false
            }, willHide: { hides += 1 })
        var willClose = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: controller.window, queue: nil
        ) { _ in willClose += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        await controller.requestClose()?.value
        #expect(closes == 1)
        #expect(hides == 1)
        #expect(willClose == 1)
    }

    @Test func commandWFiresTheCloseHandlerOnce() throws {
        var calls = 0
        let window = ShellWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        window.closeHandler = {
            calls += 1
            return true
        }
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(window.performKeyEquivalent(with: event))
        #expect(calls == 1)
    }
}
