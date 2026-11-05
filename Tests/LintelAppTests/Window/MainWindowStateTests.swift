import AppKit
import Foundation
import LintelKit
import SwiftUI
import Testing

@testable import LintelApp

/// Spec `2026-11-04-lintel-main-window`, step 1.2: the main window's mode, section and pane restore, the frame
/// fallback and the `--qa-window` argument.
@Suite struct MainWindowStateTests {
    let panes = ["general", "features", "permissions", "advanced", "clipboard"]

    private func store(mode: String? = nil, section: String? = nil, pane: String? = nil) -> InMemorySettingsStore {
        var values: [String: SettingValue] = [:]
        values[SettingsKeys.mainWindowMode] = mode.map(SettingValue.string)
        values[SettingsKeys.mainWindowSection] = section.map(SettingValue.string)
        values[SettingsKeys.mainWindowSettingsPane] = pane.map(SettingValue.string)
        return InMemorySettingsStore(values)
    }

    @Test func theKeysKeepTheirNames() {
        #expect(SettingsKeys.mainWindowMode == "app.mainWindow.mode")
        #expect(SettingsKeys.mainWindowSection == "app.mainWindow.section")
        #expect(SettingsKeys.mainWindowSettingsPane == "app.mainWindow.settingsPane")
    }

    @Test func noRegisteredSectionMeansSettingsMode() {
        for stored in [nil, "workspace", "settings", "bogus"] {
            let state = MainWindowState.restore(
                from: store(mode: stored, section: "notes"), sections: [], settingsPanes: panes)
            #expect(state == MainWindowState(mode: .settings, section: nil, settingsPane: "general"))
        }
    }

    @Test func aStoredPaneIsKeptWithoutSections() {
        let state = MainWindowState.restore(
            from: store(mode: "workspace", pane: "clipboard"), sections: [], settingsPanes: panes)
        #expect(state == MainWindowState(mode: .settings, section: nil, settingsPane: "clipboard"))
    }

    @Test func anEmptyStoreOpensTheFirstSection() {
        let state = MainWindowState.restore(from: store(), sections: ["notes", "other"], settingsPanes: panes)
        #expect(state == MainWindowState(mode: .workspace, section: "notes", settingsPane: "general"))
    }

    @Test func aKnownSettingsPaneIsRestored() {
        let state = MainWindowState.restore(
            from: store(mode: "settings", section: "other", pane: "clipboard"), sections: ["notes", "other"],
            settingsPanes: panes)
        #expect(state == MainWindowState(mode: .settings, section: "other", settingsPane: "clipboard"))
    }

    @Test func anUnknownPaneRestoresToTheFirstSection() {
        let state = MainWindowState.restore(
            from: store(mode: "settings", pane: "gone"), sections: ["notes"], settingsPanes: panes)
        #expect(state == MainWindowState(mode: .workspace, section: "notes", settingsPane: "general"))
    }

    @Test func anUnknownPaneWithoutSectionsRestoresToGeneral() {
        let state = MainWindowState.restore(
            from: store(mode: "settings", pane: "gone"), sections: [], settingsPanes: panes)
        #expect(state == MainWindowState(mode: .settings, section: nil, settingsPane: "general"))
    }

    @Test func anUnknownSectionRestoresToTheFirstSection() {
        let state = MainWindowState.restore(
            from: store(mode: "workspace", section: "gone"), sections: ["notes", "other"], settingsPanes: panes)
        #expect(state == MainWindowState(mode: .workspace, section: "notes", settingsPane: "general"))
    }

    @Test func aKnownSectionIsRestored() {
        let state = MainWindowState.restore(
            from: store(mode: "workspace", section: "other", pane: "advanced"), sections: ["notes", "other"],
            settingsPanes: panes)
        #expect(state == MainWindowState(mode: .workspace, section: "other", settingsPane: "advanced"))
    }

    @Test func valuesOfTheWrongTypeAreIgnored() {
        let store = InMemorySettingsStore([
            SettingsKeys.mainWindowMode: .bool(true), SettingsKeys.mainWindowSettingsPane: .integer(3),
        ])
        let state = MainWindowState.restore(from: store, sections: [], settingsPanes: panes)
        #expect(state == MainWindowState(mode: .settings, section: nil, settingsPane: "general"))
    }

    @Test func saveWritesWhatRestoreReads() {
        let settings = InMemorySettingsStore()
        MainWindowState(mode: .settings, section: "notes", settingsPane: "clipboard").save(to: settings)
        #expect(settings.value(forKey: SettingsKeys.mainWindowMode) == .string("settings"))
        #expect(settings.value(forKey: SettingsKeys.mainWindowSection) == .string("notes"))
        #expect(settings.value(forKey: SettingsKeys.mainWindowSettingsPane) == .string("clipboard"))
        let restored = MainWindowState.restore(from: settings, sections: ["notes"], settingsPanes: panes)
        #expect(restored == MainWindowState(mode: .settings, section: "notes", settingsPane: "clipboard"))

        MainWindowState(mode: .settings, section: nil, settingsPane: "general").save(to: settings)
        #expect(settings.value(forKey: SettingsKeys.mainWindowSection) == nil)
    }

    // MARK: Frame fallback

    let main = NSRect(x: 0, y: 0, width: 1440, height: 875)
    let side = NSRect(x: 1440, y: 0, width: 1920, height: 1055)

    @Test func aFrameOnAnyScreenIsKept() {
        let onMain = NSRect(x: 100, y: 100, width: 1180, height: 720)
        let onSide = NSRect(x: 2000, y: 200, width: 1180, height: 720)
        #expect(MainWindowController.validatedFrame(onMain, screens: [main, side]) == onMain)
        #expect(MainWindowController.validatedFrame(onSide, screens: [main, side]) == onSide)
    }

    @Test func aFrameOffEveryScreenIsCenteredOnTheMainScreen() {
        // The side display is gone; the frame was saved there.
        let saved = NSRect(x: 2000, y: 200, width: 1180, height: 720)
        let frame = MainWindowController.validatedFrame(saved, screens: [main])
        #expect(frame == NSRect(x: 130, y: 78, width: 1180, height: 720))
    }

    @Test func aBarelyVisibleFrameCountsAsOffScreen() {
        let edge = NSRect(x: 1400, y: 100, width: 1180, height: 720)
        let frame = MainWindowController.validatedFrame(edge, screens: [main])
        #expect(frame.midX == main.midX)
    }

    @Test func aCenteredFrameFitsASmallMainScreen() {
        let small = NSRect(x: 0, y: 0, width: 1024, height: 640)
        let frame = MainWindowController.validatedFrame(
            NSRect(x: 5000, y: 5000, width: 1180, height: 720), screens: [small])
        #expect(frame == NSRect(x: 0, y: 0, width: 1024, height: 640))
    }

    @Test func aFrameThatWasNotRestoredIsCentered() {
        let fresh = NSRect(x: 0, y: 0, width: 1180, height: 720)
        let frame = MainWindowController.validatedFrame(fresh, screens: [main, side], isRestored: false)
        #expect(frame == NSRect(x: 130, y: 78, width: 1180, height: 720))
    }

    @Test func withoutScreensTheFrameIsLeftAlone() {
        let frame = NSRect(x: 5000, y: 5000, width: 1180, height: 720)
        #expect(MainWindowController.validatedFrame(frame, screens: []) == frame)
    }

    // MARK: QA argument

    @Test func theQAWindowArgumentTakesAMode() throws {
        #expect(try QAOptions.parse(["--qa-window", "workspace"])?.windowMode == .workspace)
        #expect(try QAOptions.parse(["--qa-window", "settings"])?.windowMode == .settings)
        #expect(try QAOptions.parse(["--qa"])?.windowMode == nil)
        #expect(throws: QAOptions.ParseError.invalidValue("--qa-window", "notes")) {
            _ = try QAOptions.parse(["--qa-window", "notes"])
        }
        #expect(throws: QAOptions.ParseError.missingValue("--qa-window")) {
            _ = try QAOptions.parse(["--qa-window"])
        }
    }
}

/// The controller itself, built without frame autosave so nothing reaches the user's defaults.
@MainActor
@Suite struct MainWindowControllerTests {
    final class Recorder {
        var states: [MainWindowState] = []
    }

    private func section(_ id: String, order: Int) -> WorkspaceSection {
        WorkspaceSection(
            id: id, title: "Section", symbolName: "doc", order: order, makeView: { AnyView(EmptyView()) })
    }

    private func makeController(
        settings: InMemorySettingsStore, sections: [WorkspaceSection] = [], recorder: Recorder
    ) -> MainWindowController {
        let controller = MainWindowController(
            settings: settings,
            sections: { sections },
            settingsPanes: { ["general", "features", "clipboard"] },
            screens: { [NSRect(x: 0, y: 0, width: 1440, height: 875)] },
            frameAutosaveName: nil,
            makeContent: { state, _ in
                recorder.states.append(state)
                return AnyView(EmptyView())
            })
        controller.activatesApp = false
        return controller
    }

    @Test func onlySettingsModeHasTheTransparentTitleBar() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        MainWindowController.applyChrome(to: window, mode: .settings)
        #expect(window.styleMask.contains(.fullSizeContentView) && window.titlebarAppearsTransparent)
        MainWindowController.applyChrome(to: window, mode: .workspace)
        #expect(!window.styleMask.contains(.fullSizeContentView) && !window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .visible)
    }

    @Test func theWindowIsBuiltOnceWithTheSpecSizes() throws {
        let recorder = Recorder()
        let controller = makeController(settings: InMemorySettingsStore(), recorder: recorder)
        defer { controller.close() }
        controller.showSettings()
        let window = try #require(controller.window)
        #expect(window.title == "Lintel")
        #expect(window.contentMinSize == MainWindowController.minimumSize)
        // Settings mode (step 6.5a): the content runs under a transparent title bar, so the window is the
        // prototype's 1180 × 720 with the traffic lights over the sidebar.
        #expect(window.frame.size == MainWindowController.defaultSize)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden)
        #expect(window.styleMask.contains(.resizable))
        #expect(!window.isRestorable)
        controller.showSettings("clipboard")
        #expect(controller.window === window)
        #expect(recorder.states.map(\.settingsPane) == ["general", "clipboard"])
    }

    @Test func workspaceWithoutSectionsOpensSettings() {
        let settings = InMemorySettingsStore()
        let recorder = Recorder()
        let controller = makeController(settings: settings, recorder: recorder)
        defer { controller.close() }
        controller.showWorkspace()
        #expect(controller.state == MainWindowState(mode: .settings, section: nil, settingsPane: "general"))
        #expect(settings.value(forKey: SettingsKeys.mainWindowMode) == .string("settings"))
    }

    @Test func switchingModesIsStoredAndRestored() async {
        let settings = InMemorySettingsStore()
        let recorder = Recorder()
        let sections = [section("notes", order: 10), section("other", order: 20)]
        let controller = makeController(settings: settings, sections: sections, recorder: recorder)
        defer { controller.close() }
        controller.showWorkspace("other")
        #expect(controller.state == MainWindowState(mode: .workspace, section: "other", settingsPane: "general"))
        // Leaving a visible section waits for its `willHide`.
        await controller.showSettings("gone")?.value
        #expect(controller.state == MainWindowState(mode: .settings, section: "other", settingsPane: "general"))
        controller.showSettings("clipboard")
        controller.show()
        #expect(controller.state == MainWindowState(mode: .settings, section: "other", settingsPane: "clipboard"))
        controller.showWorkspace()
        #expect(controller.state == MainWindowState(mode: .workspace, section: "other", settingsPane: "clipboard"))
    }
}
