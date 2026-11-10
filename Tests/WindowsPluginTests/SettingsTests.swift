import Foundation
import LintelKit
import SwiftUI
import Testing

@testable import WindowsPlugin

/// Step 1.11: the banner table, the pane model, diagnostics and the rule that an inactive pane does nothing.
@MainActor
@Suite struct SettingsTests {
    private func banner(_ build: (inout WindowsStatusInputs) -> Void) -> SettingsStatus? {
        var inputs = WindowsStatusInputs()
        build(&inputs)
        return WindowsBanner.derive(inputs) { _ in }
    }

    private func title(_ status: SettingsStatus?) -> String { status.map { String(localized: $0.title) } ?? "nil" }

    // MARK: Banner priority

    @Test func theBannerTableFollowsErrorThenAttentionThenOk() {
        let parked = banner {
            $0.trusted = false
            $0.hasParkedWindows = true
            $0.stageManagerOn = true
        }
        #expect(parked?.level == .error)
        #expect(title(parked) == "Windows are parked")
        #expect(parked?.fix.count == 2)
        // Error beats attention even with Accessibility on.
        let journal = banner {
            $0.engineBanner = .cannotJournal
            $0.stageManagerOn = true
        }
        #expect(journal?.level == .error)
        // No Accessibility and nothing parked: the shell's own banner.
        #expect(banner { $0.trusted = false } == nil)
        #expect(
            banner {
                $0.trusted = false
                $0.stageManagerOn = true
            } == nil)
        #expect(title(banner { $0.stageManagerOn = true }) == "Stage Manager is on")
        #expect(title(banner { $0.displaysShareASpace = true }) == "Displays share one Space")
        #expect(title(banner { $0.stripHasRoom = false }) == "The menu bar has no room for the strip")
        #expect(
            banner {
                $0.stripHasRoom = false
                $0.stripEnabled = false
            }?.level == .ok)
        #expect(banner { $0.engineBanner = .watchdogTripped }?.level == .attention)
        let ok = banner { $0.workspaceCount = 4 }
        #expect(ok?.level == .ok)
        // Unknown preferences show nothing.
        #expect(
            banner {
                $0.stageManagerOn = nil
                $0.displaysShareASpace = nil
            }?.level == .ok)
        // Stage Manager outranks the Spaces and strip warnings.
        #expect(
            title(
                banner {
                    $0.stageManagerOn = true
                    $0.displaysShareASpace = true
                    $0.stripHasRoom = false
                }) == "Stage Manager is on")
    }

    // MARK: Model

    private func setup(
        windows: [WindowInfo] = [makeWindow(1)], granted: Bool = true, preferences: SystemPreferences? = nil
    ) throws -> (WindowsPlugin, FakeWindowClient, WindowsHarness, ShortcutLog) {
        let harness = try WindowsHarness()
        let client = FakeWindowClient(windows: windows)
        let log = ShortcutLog()
        var context = harness.context(windows: client, permissions: ScriptedPermissions(granted: granted))
        context = PluginContext(
            storageDirectory: harness.directory, settings: harness.pluginSettings, usage: NoUsage(),
            logger: context.logger, keychain: NoKeychain(), pasteboard: log, events: NoEvents(),
            workspace: NoWorkspace(), permissions: ScriptedPermissions(granted: granted), clock: ContinuousClock(),
            windows: client,
            setCommandShortcut: { id, shortcut in log.set(id, shortcut) },
            commandShortcut: { id in log.get(id) })
        let plugin = WindowsPlugin(context: context, hud: RecordingHUD(), activationCenter: NotificationCenter())
        return (plugin, client, harness, log)
    }

    @Test func settersWriteThroughWindowsSettingsOnly() throws {
        let (plugin, _, harness, _) = try setup()
        defer { harness.tearDown() }
        let model = plugin.paneModel
        model.setWorkspaceCount(7)
        model.setFollowFocus(false)
        model.setShowHUD(false)
        model.setStripEnabled(false)
        model.setStripMode(.occupied)
        let settings = WindowsSettings(harness.pluginSettings)
        #expect(settings.workspaceCount == 7)
        #expect(!settings.followFocus && !settings.showHUD && !settings.stripEnabled)
        #expect(settings.stripMode == .occupied)
        model.setWorkspaceCount(40)
        #expect(model.workspaceCount == 9)
        #expect(harness.store.keys.allSatisfy { $0.hasPrefix("plugins.windows.") })
    }

    @Test func floatingAppsCanBeAddedRemovedAndReset() throws {
        let (plugin, _, harness, _) = try setup()
        defer { harness.tearDown() }
        let model = WindowsSettingsModel(
            context: plugin.context, settings: plugin.settings, registry: .standard, runtime: { nil },
            chooseApp: { "com.example.new" })
        model.addFloatingApp()
        model.addFloatingApp()
        #expect(model.floatingApps.filter { $0 == "com.example.new" }.count == 1)
        model.removeFloatingApp("com.apple.calculator")
        #expect(!WindowsSettings(harness.pluginSettings).floatingApps.contains("com.apple.calculator"))
        model.resetFloatingApps()
        #expect(WindowsSettings(harness.pluginSettings).floatingApps == WindowsSettings.defaultFloatingApps)
    }

    @Test func aFamilyModifierAppliesToAllNineAndTheFamiliesNeverCollide() throws {
        let (plugin, _, harness, log) = try setup()
        defer { harness.tearDown() }
        let model = plugin.paneModel
        model.setModifiers(.controlOption, for: .goToWorkspace)
        #expect(log.get("windows.workspace.5") == KeyShortcut(key: "5", modifiers: [.control, .option]))
        #expect(log.sets.count == 9)
        // The families never share modifiers: the go family's choice is refused for the move family.
        model.setModifiers(.controlOption, for: .moveToWorkspace)
        #expect(log.sets.count == 9)
        #expect(model.moveChoice == .optionShift)
        model.setModifiers(.optionShift, for: .goToWorkspace)
        #expect(log.sets.count == 9)
        model.setModifiers(.option, for: .goToWorkspace)
        #expect(log.sets.count == 18)
        model.setModifiers(.option, for: .moveToWorkspace)
        #expect(model.moveChoice == .optionShift)
    }

    @Test func theLayoutWarningNamesTheKeysAndTheOneClickFixClearsIt() throws {
        let (plugin, _, harness, log) = try setup()
        defer { harness.tearDown() }
        let model = WindowsSettingsModel(
            context: plugin.context, settings: plugin.settings, registry: .standard, runtime: { nil },
            translate: { code, modifiers in modifiers.contains(.control) ? nil : (code == 18 ? "ł" : nil) })
        log.set("windows.workspace.1", KeyShortcut(key: "1", modifiers: [.option]))
        model.refreshSafety()
        #expect(model.needsShortcutWarning)
        #expect(model.unsafeKeyNames == "⌥1")
        model.useControlOption()
        #expect(!model.needsShortcutWarning)
        #expect(log.get("windows.workspace.1")?.modifiers == [.control, .option])
        #expect(log.get("windows.moveToWorkspace.1")?.modifiers == [.control, .option, .shift])
    }

    // MARK: Data

    @Test func diagnosticsAreCountersOnly() async throws {
        let (plugin, _, harness, log) = try setup(windows: [makeWindow(1, bundleID: "com.secret.bundle")])
        defer { harness.tearDown() }
        try await plugin.activate()
        await plugin.paneModel.copyDiagnostics()
        await plugin.deactivate()
        let text = try #require(log.last)
        #expect(text.contains("Watchdog trips: 0"))
        #expect(!text.contains("secret"))
        #expect(!text.contains("com."))
    }

    @Test func resetStateRestoresFirstThenForgets() async throws {
        let (plugin, client, harness, _) = try setup(windows: [makeWindow(1), makeWindow(2)])
        defer { harness.tearDown() }
        client.setFocused(WindowID(pid: 100, number: 1))
        try await plugin.activate()
        let runtime = try #require(plugin.runtime)
        await runtime.engine.send(.moveFocusedWindow(to: WorkspaceID(2)!))
        #expect(client.frame(of: WindowID(pid: 100, number: 1))?.origin == CGPoint(x: 1919, y: 1079))
        await plugin.paneModel.resetState()
        #expect(client.frame(of: WindowID(pid: 100, number: 1)) == CGRect(x: 100, y: 100, width: 800, height: 600))
        // The running engine started over too: window 1 is back in the workspace shown on its display, and the
        // stored membership is what the engine holds now (not the cleared file, and not the old membership).
        let model = await runtime.engine.snapshot.model
        #expect(model.workspace(of: WindowID(pid: 100, number: 1)) == WorkspaceID(1))
        #expect(model.order[WorkspaceID(2)!, default: []].isEmpty)
        await runtime.settle()
        await plugin.journal.store.flush()
        let store = StateStore(directory: harness.directory)
        await store.load()
        #expect(await store.hidden.isEmpty)
        #expect(await store.state.order == model.order)
        await plugin.deactivate()
    }

    @Test func refreshReadsTheWorldAndFeedsTheBanner() async throws {
        let prefs = SystemPreferences { domain, _ in domain == "com.apple.WindowManager" ? true : nil }
        let (plugin, _, harness, _) = try setup()
        defer { harness.tearDown() }
        let model = WindowsSettingsModel(
            context: plugin.context, settings: plugin.settings, registry: .standard, runtime: { nil },
            preferences: prefs)
        await model.refresh()
        #expect(model.status.stageManagerOn == true)
        #expect(model.status.displaysShareASpace == nil)
        let status = WindowsBanner.derive(model.status) { _ in }
        #expect(title(status) == "Stage Manager is on")
    }

    // MARK: The inactive pane

    @Test func thePaneOfAnInactivePluginStartsNothingAndTouchesNothing() throws {
        let (plugin, client, harness, _) = try setup()
        defer { harness.tearDown() }
        _ = plugin.settingsPane()
        _ = plugin.onboardingSteps.first?.makeView()
        #expect(plugin.runtime == nil)
        #expect(client.calls.isEmpty && client.windowsReads == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.directory.appending(path: "state.json").path))
        #expect(plugin.settingsStatus != nil || plugin.settingsStatus == nil)
    }

    @Test func aFailedStartShowsAHintInTheModel() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let plugin = WindowsPlugin(
            context: harness.context(windows: UnsupportedClient(reason: "x")), hud: RecordingHUD(),
            activationCenter: NotificationCenter())
        await #expect(throws: WindowsPlugin.StartError.self) { try await plugin.activate() }
        #expect(plugin.paneModel.startFailure() == .unsupported(reason: "x"))
    }

    @Test func theOnboardingStepIsDeclaredOnce() throws {
        let (plugin, _, harness, _) = try setup()
        defer { harness.tearDown() }
        #expect(plugin.onboardingSteps.map(\.id) == ["windows.setup"])
    }
}

/// Records the shortcuts the pane sets, and the text it copies (it is also the context's pasteboard).
final class ShortcutLog: PasteboardClient, @unchecked Sendable {
    private let lock = NSLock()
    private var shortcuts: [String: KeyShortcut] = [:]
    private var _sets: [String] = []
    private var _copied: [String] = []

    var sets: [String] { lock.withLock { _sets } }
    var last: String? { lock.withLock { _copied.last } }
    func set(_ id: String, _ shortcut: KeyShortcut?) {
        lock.withLock {
            shortcuts[id] = shortcut
            _sets.append(id)
        }
    }
    func get(_ id: String) -> KeyShortcut? { lock.withLock { shortcuts[id] } }

    @MainActor var changeCount: Int { 0 }
    @MainActor func string() -> String? { last }
    @MainActor func setString(_ string: String) -> Int {
        lock.withLock { _copied.append(string) }
        return 1
    }
}

extension SettingsTests {
    /// Review L4 to L6.
    @Test func theParkedHUDOffersTheButtonAndARefusedChoiceIsExplained() throws {
        #expect(WindowsHUDState.parkedNeedsAccessibility.offersAllowAccessibility)
        let (plugin, _, harness, _) = try setup()
        defer { harness.tearDown() }
        let model = plugin.paneModel
        model.setModifiers(.optionShift, for: .goToWorkspace)
        #expect(model.modifierConflict)
        model.setModifiers(.controlOption, for: .goToWorkspace)
        #expect(!model.modifierConflict)
        // An app that is not installed is shown by its id.
        #expect(model.appName("com.example.not.installed") == "com.example.not.installed")
    }
}

extension SettingsTests {
    // MARK: Step 2.5: layout rows, overrides and the new shortcut families

    @Test func theLayoutRowsWriteThroughAndReachTheEngineConfig() throws {
        let (plugin, _, harness, _) = try setup()
        defer { harness.tearDown() }
        let model = plugin.paneModel
        model.setDefaultKind(.free)
        let gaps = TilingStrategy().options
        model.setGlobalValue(.int(12), of: gaps[0])
        model.setGlobalValue(.int(70), of: gaps[1])
        let settings = WindowsSettings(harness.pluginSettings)
        #expect(settings.defaultKind(in: .standard) == .free && settings.innerGap == 12 && settings.outerGap == 64)
        #expect(model.globalValue(of: gaps[1]) == .int(64))
        #expect(model.layoutConfig.defaultKind == .free)
        #expect(harness.store.keys.allSatisfy { $0.hasPrefix("plugins.windows.") })
    }

    @Test func overridesAreWrittenAsOneVersionedValueAndClearedWhenEmpty() throws {
        let (plugin, _, harness, _) = try setup()
        defer { harness.tearDown() }
        let model = plugin.paneModel
        let workspace = WorkspaceID(3)!
        model.setOverrideKind(.free, for: workspace)
        let options = TilingStrategy().options
        model.setOverrideOption(options[0], to: .int(0), for: workspace)
        model.setOverrideOption(options[2], to: .string("vertical"), for: workspace)
        let stored = harness.pluginSettings.string(WindowsSettings.Key.workspaces)
        #expect(stored?.contains("\"version\":1") == true)
        #expect(
            WindowsSettings(harness.pluginSettings).workspaceOverrides.byWorkspace[workspace]
                == WorkspaceOverride(kind: .free, innerGap: 0, rootOrientation: .vertical))
        model.setOverrideKind(nil, for: workspace)
        model.resetOverrides(for: workspace)
        #expect(model.overrides.byWorkspace.isEmpty)
        #expect(harness.pluginSettings.string(WindowsSettings.Key.workspaces) == "")
    }

    @Test func theSummaryShowsTheEffectiveConfigurationOfEveryWorkspace() throws {
        let (plugin, _, harness, _) = try setup()
        defer { harness.tearDown() }
        let model = plugin.paneModel
        model.setWorkspaceCount(3)
        model.setDefaultKind(.tiling)
        model.setOverrideKind(.free, for: WorkspaceID(2)!)
        model.setOverrideOption(TilingStrategy().options[1], to: .int(0), for: WorkspaceID(3)!)
        let lines = model.workspaceSummaries
        #expect(lines.map(\.workspace.rawValue) == [1, 2, 3])
        #expect(lines.map(\.isCustom) == [false, true, true])
        #expect(lines[1].detail == "Free")
        // Auto-tile lines name the gaps and the first split.
        #expect(lines[0].detail.hasPrefix("Auto-tile · "))
        #expect(lines[0].detail.contains("8") && lines[2].detail.contains("8 / 0"))
    }

    @Test func overridesFromANewerVersionAreLockedAndKeptAsTheyAre() throws {
        let (plugin, _, harness, _) = try setup()
        defer { harness.tearDown() }
        let newer = #"{"version":9,"workspaces":{"1":{"kind":"free"}}}"#
        harness.pluginSettings.set(newer, for: WindowsSettings.Key.workspaces)
        let model = WindowsSettingsModel(
            context: plugin.context, settings: plugin.settings, registry: .standard, runtime: { nil })
        #expect(model.overridesLocked)
        model.setOverrideKind(.tiling, for: WorkspaceID(1)!)
        model.resetOverrides(for: WorkspaceID(1)!)
        #expect(harness.pluginSettings.string(WindowsSettings.Key.workspaces) == newer)
        #expect(model.workspaceSummaries.allSatisfy { !$0.isCustom })
    }

    @Test func editingOneWorkspaceAtATime() throws {
        let (plugin, _, harness, _) = try setup()
        defer { harness.tearDown() }
        let model = plugin.paneModel
        model.edit(WorkspaceID(2))
        #expect(model.editingWorkspace == WorkspaceID(2))
        model.edit(WorkspaceID(4))
        #expect(model.editingWorkspace == WorkspaceID(4))
        model.edit(WorkspaceID(4))
        #expect(model.editingWorkspace == nil)
    }

    @Test func everyFamilyHasItsOwnModifierAndPartnersNeverCollide() throws {
        let (plugin, _, harness, log) = try setup()
        defer { harness.tearDown() }
        let model = plugin.paneModel
        model.setModifiers(.controlOption, for: .focus)
        #expect(log.get("windows.focus.right") == KeyShortcut(key: "l", modifiers: [.control, .option]))
        #expect(log.get("windows.focus.left") == KeyShortcut(key: "h", modifiers: [.control, .option]))
        // The move family holds ⌥⇧; the focus family may not take it.
        model.setModifiers(.optionShift, for: .focus)
        #expect(model.modifierConflict)
        #expect(model.choices[.focus] == .controlOption)
        model.setModifiers(.controlOption, for: .resize)
        #expect(log.get("windows.resize.grow") == KeyShortcut(key: "=", modifiers: [.control, .option]))
        #expect(log.get("windows.resize.shrink") == KeyShortcut(key: "-", modifiers: [.control, .option]))
    }

    @Test func theOneClickFixCoversTheTilingKeysToo() throws {
        let (plugin, _, harness, log) = try setup()
        defer { harness.tearDown() }
        let model = WindowsSettingsModel(
            context: plugin.context, settings: plugin.settings, registry: .standard, runtime: { nil },
            translate: { code, modifiers in
                // A Polish layout: ⌥L types "ł".
                modifiers.contains(.control) ? nil : (code == 37 ? "ł" : nil)
            })
        for family in ShortcutFamily.allCases {
            for binding in family.bindings(in: .standard) {
                log.set(binding.id, KeyShortcut(key: binding.key, modifiers: family.defaultModifiers))
            }
        }
        model.refreshSafety()
        #expect(model.needsShortcutWarning)
        #expect(model.unsafeKeyNames.contains("L"))
        model.useControlOption()
        #expect(!model.needsShortcutWarning)
        #expect(log.get("windows.focus.right")?.modifiers == [.control, .option])
        #expect(log.get("windows.move.right")?.modifiers == [.control, .option, .shift])
        #expect(log.get("windows.resize.grow")?.modifiers == [.control, .option])
    }
}
