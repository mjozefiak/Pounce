import AppKit
import Foundation
import PounceKit
import SwiftUI
import Testing

@testable import PounceApp

@Suite struct CommandShortcutTests {
    private func service(_ registrar: InMemoryHotkeyRegistrar, _ settings: InMemorySettingsStore) -> HotkeyService {
        HotkeyService(registrar: registrar, settings: settings, readOccupied: { [] })
    }

    private let history = PluginCommand(
        id: "clipboard.history",
        title: "Clipboard History",
        defaultShortcut: KeyShortcut(key: "v", modifiers: [.command, .shift]),
        panelMode: "clipboard"
    )

    @Test func theDefaultCommandShortcutIsAppliedAndShown() throws {
        let registrar = InMemoryHotkeyRegistrar()
        let hotkeys = service(registrar, InMemorySettingsStore())
        hotkeys.syncCommands([history]) { _ in }
        let shortcut = try #require(hotkeys.commandShortcut("clipboard.history"))
        #expect(shortcut.displayString == "⇧⌘V")
        #expect(registrar.handlers[.command("clipboard.history")] != nil)
    }

    @Test func aRecordedOrClearedShortcutIsNeverReplacedByTheDefault() {
        let registrar = InMemoryHotkeyRegistrar()
        let settings = InMemorySettingsStore()
        let hotkeys = service(registrar, settings)
        // The user clears the shortcut in the recorder before the command was ever synced.
        hotkeys.userRecordedCommandShortcut("clipboard.history")
        hotkeys.syncCommands([history]) { _ in }
        #expect(hotkeys.commandShortcut("clipboard.history") == nil)
        #expect(settings.value(forKey: "app.hotkey.commandDefaultsApplied") == .stringArray(["clipboard.history"]))
    }

    @Test func theMenuShowsACommandsShortcut() throws {
        let menu = NSMenu()
        let actions = ShellMenuActions(
            openPanel: {},
            openSettings: {},
            mainShortcut: { nil },
            runCommand: { _ in },
            commandShortcut: { id in
                id == "clipboard.history" ? HotkeyShortcut(KeyShortcut(key: "v", modifiers: [.command, .shift])) : nil
            }
        )
        StatusMenuBuilder(actions: actions).populate(menu, commands: [history])
        let item = try #require(menu.items.first { $0.title == "Clipboard History" })
        #expect(item.keyEquivalent == "v")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
    }

    @MainActor
    @Test func pluginsGetTheShellRecorder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pounce-recorder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = AppEnvironment(
            dataRoot: root,
            cachesRoot: root,
            settings: InMemorySettingsStore(),
            keychain: InMemoryKeychainClient(),
            pasteboardName: nil,
            usage: InMemoryUsageRecorder(),
            registersGlobalHotkeys: false
        )
        let asked = RecorderRequests()
        let context = environment.makeContext(
            for: PluginManifest(id: "clipboard", displayName: "Clipboard History", symbolName: "doc", order: 30)
        ) {
        } makeShortcutRecorder: { id in
            asked.ids.append(id)
            return AnyView(EmptyView())
        }
        _ = context.makeShortcutRecorder("clipboard.history")
        #expect(asked.ids == ["clipboard.history"])
    }
}

@MainActor
final class RecorderRequests {
    var ids: [String] = []
}

@Suite @MainActor struct PluginOnboardingTests {
    private func step(_ id: String) -> OnboardingStep {
        OnboardingStep(id: id, title: "Step", symbolName: "star") { AnyView(EmptyView()) }
    }

    @Test func pendingStepsSkipCompletedOnes() {
        let store = InMemorySettingsStore()
        let settings = AppSettings(store: store)
        let hotkeys = HotkeyService(registrar: InMemoryHotkeyRegistrar(), settings: store, readOccupied: { [] })
        let steps = [step("clipboard.intro"), step("files.intro")]
        let onboarding = OnboardingController(hotkeys: hotkeys, settings: settings) { steps }
        #expect(onboarding.hasPendingSteps)
        #expect(onboarding.pendingPluginSteps.map(\.id) == ["clipboard.intro", "files.intro"])

        settings.shortcutOnboardingCompleted = true
        settings.completedOnboardingSteps = ["clipboard.intro"]
        #expect(onboarding.pendingPluginSteps.map(\.id) == ["files.intro"])
        #expect(store.value(forKey: "app.onboarding.completedSteps") == .stringArray(["clipboard.intro"]))

        settings.completedOnboardingSteps = ["clipboard.intro", "files.intro"]
        #expect(!onboarding.hasPendingSteps)
    }

    @Test func closingAPluginStepCountsAsDone() {
        let store = InMemorySettingsStore()
        let settings = AppSettings(store: store)
        settings.shortcutOnboardingCompleted = true
        let hotkeys = HotkeyService(registrar: InMemoryHotkeyRegistrar(), settings: store, readOccupied: { [] })
        let onboarding = OnboardingController(hotkeys: hotkeys, settings: settings) { [self] in
            [step("clipboard.intro")]
        }
        onboarding.activatesApp = false
        onboarding.showPendingSteps()
        #expect(onboarding.currentPluginStep == "clipboard.intro")
        onboarding.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(settings.completedOnboardingSteps == ["clipboard.intro"])
        #expect(!onboarding.hasPendingSteps)
    }
}

#if DEBUG
@Suite struct QAPhase2OptionsTests {
    @Test func parsesTheClipboardOptions() throws {
        let options = try #require(
            try QAOptions.parse([
                "Pounce", "--qa-settings", "clipboard", "--qa-onboarding-step", "clipboard.intro",
                "--qa-pasteboard-access", "ask", "--qa-accessibility", "denied",
                "--qa-setting", "plugins.clipboard.qaSeed=demo",
            ])
        )
        #expect(options.settingsPane == "clipboard")
        #expect(options.onboardingStep == "clipboard.intro")
        #expect(options.pasteboardAccess == .ask)
        #expect(options.accessibility == .denied)
        #expect(options.settings["plugins.clipboard.qaSeed"] == .string("demo"))
    }

    @Test func rejectsBadValues() {
        #expect(throws: QAOptions.ParseError.invalidValue("--qa-pasteboard-access", "maybe")) {
            _ = try QAOptions.parse(["--qa-pasteboard-access", "maybe"])
        }
        #expect(throws: QAOptions.ParseError.invalidValue("--qa-accessibility", "yes")) {
            _ = try QAOptions.parse(["--qa-accessibility", "yes"])
        }
    }

    @MainActor
    @Test func theQAEnvironmentPassesTheOverridesToPlugins() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pounce-qa-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var options = QAOptions(dataRoot: root)
        options.pasteboardAccess = .alwaysDeny
        options.accessibility = .granted
        let environment = try AppEnvironment.qa(options)
        let context = environment.makeContext(
            for: PluginManifest(id: "clipboard", displayName: "Clipboard History", symbolName: "doc", order: 30))
        #expect(context.pasteboard.accessBehavior == PasteboardAccess.alwaysDeny)
        #expect(context.permissions.status(of: .accessibility) == .granted)
        NSPasteboard(name: try #require(environment.pasteboardName)).releaseGlobally()
    }
}
#endif

@Suite struct KeyboardLayoutTests {
    @Test func findsTheKeyThatTypesV() {
        // Dvorak puts "v" on the ANSI period key (47).
        let dvorak: [CGKeyCode: String] = [47: "v", 9: "k"]
        #expect(KeyboardLayout.keyCode(producing: "v") { dvorak[$0] } == 47)
        #expect(KeyboardLayout.keyCode(producing: "v") { $0 == 9 ? "V" : nil } == 9)
        #expect(KeyboardLayout.keyCode(producing: "v") { _ in "м" } == nil)
    }

    @MainActor
    @Test func theCurrentLayoutGivesAKeyCode() {
        // Reads the layout only; never posts an event.
        #expect(KeyboardLayout.pasteKeyCode() < 128)
    }
}
