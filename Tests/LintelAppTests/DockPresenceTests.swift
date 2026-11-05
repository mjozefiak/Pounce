import AppKit
import LintelKit
import Testing

@testable import LintelApp

@MainActor
@Suite struct DockPresenceTests {
    @Test func theDockIconIsAnActivationPolicyNotAnInfoPlistChange() {
        #expect(DockPresence.policy(showInDock: true) == .regular)
        #expect(DockPresence.policy(showInDock: false) == .accessory)
    }

    @Test func aDockClickOpensTheMainWindowUnlessAWindowIsOpen() {
        #expect(DockPresence.reopenAction(hasVisibleWindows: false) == .openMainWindow)
        #expect(DockPresence.reopenAction(hasVisibleWindows: true) == .nothing)
    }

    @Test func onlyTheLauncherPanelVisibleCountsAsNoVisibleWindow() {
        #expect(!DockPresence.hasVisibleWindows([]))
        #expect(!DockPresence.hasVisibleWindows([.launcherPanel]))
        #expect(!DockPresence.hasVisibleWindows([.launcherPanel, .hud]))
        let onlyPanel = DockPresence.hasVisibleWindows([.launcherPanel])
        #expect(DockPresence.reopenAction(hasVisibleWindows: onlyPanel) == .openMainWindow)
    }

    @Test func realWindowsCountAsVisible() {
        for role in [KeyWindowRole.mainWindow, .sheet, .childWindow, .popover, .openSavePanel, .about, .other] {
            #expect(DockPresence.hasVisibleWindows([.launcherPanel, role]))
        }
    }

    @Test func theDockIconIsOnByDefault() {
        let settings = AppSettings(store: InMemorySettingsStore())
        #expect(settings.showInDock)
    }

    @Test func aStoredChoiceIsKept() {
        let off = AppSettings(store: InMemorySettingsStore([SettingsKeys.showInDock: .bool(false)]))
        #expect(!off.showInDock)
        let on = AppSettings(store: InMemorySettingsStore([SettingsKeys.showInDock: .bool(true)]))
        #expect(on.showInDock)
    }

    @Test func turningItOffIsStoredAndAnnouncedAtOnce() {
        let store = InMemorySettingsStore()
        let settings = AppSettings(store: store)
        var announced: [Bool] = []
        settings.showInDockChanged = { announced.append($0) }
        settings.showInDock = false
        settings.showInDock = true
        #expect(announced == [false, true])
        #expect(store.value(forKey: SettingsKeys.showInDock) == .bool(true))
    }

    @Test func theKeyIsInTheAppNamespace() {
        #expect(SettingsKeys.showInDock == "app.showInDock")
    }
}
