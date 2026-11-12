import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// Window management v2, Phase 3: the per-app rules (the stored value, the resolver, the reducer and the Rules
/// section of the Configure model).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct AppRulesTests {
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }
    private let main = FakeWindowClient.mainDisplay

    // MARK: The stored value

    @Test func theStoredValueRoundTripsAndKeepsOneEntryPerApp() {
        var rules = AppRules()
        rules.set(bundleID: "com.example.a", workspace: 2)
        rules.set(bundleID: "com.example.b", workspace: 9)
        rules.set(bundleID: "com.example.a", workspace: 3)
        #expect(rules.entries.map(\.workspace) == [9, 3])
        #expect(AppRules(json: rules.json) == rules)
        rules.set(bundleID: "com.example.a", workspace: nil)
        rules.set(bundleID: "com.example.b", workspace: nil)
        #expect(rules.json == "")
    }

    @Test func invalidRulesAreDroppedAndTheLastDuplicateWinsOnRead() {
        let json = """
            {"version":1,"rules":[{"bundleID":"a","workspace":0},{"bundleID":"b","workspace":10},
            {"bundleID":"","workspace":1},{"bundleID":"c","workspace":1},{"bundleID":"c","workspace":2},
            {"bundleID":"\(String(repeating: "x", count: 256))","workspace":1}]}
            """
        let rules = AppRules(json: json)
        #expect(rules.entries == [AppRules.Entry(bundleID: "c", workspace: 2)])
        var edit = AppRules()
        edit.set(bundleID: "z", workspace: 12)
        #expect(edit.entries.isEmpty)
    }

    @Test func aDamagedValueReadsAsNoRulesAndANewerOneIsKeptReadOnly() {
        #expect(AppRules(json: "{{").entries.isEmpty)
        #expect(AppRules(json: nil).entries.isEmpty)
        let newer = AppRules(json: #"{"version":2,"rules":[{"bundleID":"a","workspace":1}]}"#)
        #expect(newer.entries.isEmpty && newer.isReadOnly)
    }

    // MARK: The resolver

    @Test func floatWinsAndAWorkspaceThatIsOffDoesNotApply() {
        let rules = AppRules([
            AppRules.Entry(bundleID: "a", workspace: 3), AppRules.Entry(bundleID: "b", workspace: 8),
            AppRules.Entry(bundleID: "f", workspace: 2),
        ])
        let floating: Set<String> = ["f"]
        func resolve(_ id: String, count: Int = 4) -> AppRule? {
            RuleResolver.resolve(bundleID: id, floating: floating, rules: rules, workspaceCount: count)
        }
        #expect(resolve("a") == .workspace(ws(3)))
        #expect(resolve("b") == nil)
        #expect(resolve("b", count: 9) == .workspace(ws(8)))
        #expect(resolve("f") == .float)
        #expect(resolve("unknown") == nil)
        #expect(
            RuleResolver.assignments(floating: floating, rules: rules, workspaceCount: 4) == ["a": ws(3)])
    }

    // MARK: The reducer

    private func state(_ rules: [String: WorkspaceID], windows: [WindowInfo] = []) -> EngineState {
        var state = EngineState(workspaceCount: 4)
        state.config.appWorkspaces = rules
        (state, _) = EngineReducer.reduce(
            state,
            .snapshot(
                windows: windows, displays: [main], focused: nil, processStarts: [100: 1_100, 200: 1_200], now: 1_000))
        return state
    }

    @Test func aNewWindowOfAnAppWithARuleStartsOnItsWorkspaceWithoutSwitching() {
        var s = state(["com.example.chat": ws(3)], windows: [makeWindow(1)])
        let before = s.model.current
        (s, _) = EngineReducer.reduce(
            s,
            .windowAppeared(
                makeWindow(2, pid: 200, bundleID: "com.example.chat"), processStart: 1_200, now: 1_001))
        let id = WindowID(pid: 200, number: 2)
        #expect(s.model.workspace(of: id) == ws(3))
        #expect(s.model.current == before)
        // The workspace is hidden, so the window is parked, not left on screen.
        #expect(s.parked[id] != nil)
    }

    @Test func aWindowThatWasThereAtTheStartIsNotMovedByARule() {
        let s = state(
            ["com.example.chat": ws(3)], windows: [makeWindow(2, pid: 200, bundleID: "com.example.chat")])
        #expect(s.model.workspace(of: WindowID(pid: 200, number: 2)) == ws(1))
    }

    @Test func anotherWindowOfTheSameAppWhoseFirstWindowExistsIsNotTouched() {
        var s = state(["com.example.chat": ws(3)], windows: [makeWindow(1, pid: 200, bundleID: "com.example.chat")])
        // The window that already exists is only updated, never reassigned.
        (s, _) = EngineReducer.reduce(
            s,
            .windowAppeared(makeWindow(1, pid: 200, bundleID: "com.example.chat"), processStart: 1_200, now: 1_001))
        #expect(s.model.workspace(of: WindowID(pid: 200, number: 1)) == ws(1))
    }

    @Test func anAppWithoutARuleStartsOnTheCurrentWorkspace() {
        var s = state(["com.example.chat": ws(3)])
        (s, _) = EngineReducer.reduce(
            s, .windowAppeared(makeWindow(5, bundleID: "com.example.other"), processStart: 1_100, now: 1_001))
        #expect(s.model.workspace(of: WindowID(pid: 100, number: 5)) == ws(1))
    }

    @Test func theEngineConfigurationCarriesOnlyTheActiveRules() throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let settings = WindowsSettings(harness.pluginSettings)
        settings.setWorkspaceCount(4)
        settings.setAppRules(
            AppRules([AppRules.Entry(bundleID: "a", workspace: 3), AppRules.Entry(bundleID: "b", workspace: 8)]))
        #expect(EngineConfig(settings: settings, registry: .standard).appWorkspaces == ["a": ws(3)])
        settings.setWorkspaceCount(9)
        #expect(EngineConfig(settings: settings, registry: .standard).appWorkspaces == ["a": ws(3), "b": ws(8)])
        // An app that is also on the floating list is not assigned (float wins).
        settings.setFloatingApps(["a"])
        #expect(EngineConfig(settings: settings, registry: .standard).appWorkspaces == ["b": ws(8)])
    }

    // MARK: The Rules section

    private func model() throws -> (WindowsConfigureModel, WindowsHarness) {
        let harness = try WindowsHarness()
        let log = ShortcutLog()
        let context = PluginContext(
            storageDirectory: harness.directory, settings: harness.pluginSettings, usage: NoUsage(),
            logger: harness.context().logger, keychain: NoKeychain(), pasteboard: log, events: NoEvents(),
            workspace: NoWorkspace(), permissions: ScriptedPermissions(granted: true), clock: ContinuousClock(),
            windows: FakeWindowClient(windows: []), setCommandShortcut: { log.set($0, $1) },
            commandShortcut: { log.get($0) })
        let settings = WindowsSettings(harness.pluginSettings)
        settings.setFloatingApps([])
        let pane = WindowsSettingsModel(
            context: context, settings: settings, registry: .standard, runtime: { nil },
            translate: { _, _ in nil }, chooseApp: { nil })
        return (WindowsConfigureModel(pane: pane, commands: { [] }), harness)
    }

    @Test func theListMixesFloatAndWorkspaceRulesAndAnAppHasOneEntry() throws {
        let (model, harness) = try model()
        defer { harness.tearDown() }
        #expect(model.ruleRows.isEmpty)
        #expect(model.addRule(bundleID: "com.example.a", .float))
        #expect(model.addRule(bundleID: "com.example.b", .workspace(3)))
        #expect(!model.addRule(bundleID: "com.example.a", .workspace(2)))
        #expect(model.ruleRows.map(\.choice).sorted { $0.tag < $1.tag } == [.float, .workspace(3)])
        // Changing the action moves the app from one store to the other: never both.
        model.setRule(.workspace(5), for: "com.example.a")
        #expect(!model.pane.floatingApps.contains("com.example.a"))
        #expect(model.pane.settings.appRules.workspace(of: "com.example.a") == 5)
        model.setRule(.float, for: "com.example.a")
        #expect(model.pane.floatingApps.contains("com.example.a"))
        #expect(model.pane.settings.appRules.workspace(of: "com.example.a") == nil)
        model.removeRule("com.example.b")
        #expect(model.ruleRows.map(\.bundleID) == ["com.example.a"])
        #expect(WindowsConfigureModel.ruleCount(pane: model.pane) == 1)
    }

    @Test func aRuleForAWorkspaceThatIsOffIsKeptAndMarkedInactive() throws {
        let (model, harness) = try model()
        defer { harness.tearDown() }
        model.pane.setWorkspaceCount(9)
        model.addRule(bundleID: "com.example.a", .workspace(8))
        #expect(model.ruleRows.first?.isInactive == false)
        model.pane.setWorkspaceCount(4)
        #expect(model.ruleRows.first?.isInactive == true)
        #expect(model.pane.settings.appRules.workspace(of: "com.example.a") == 8)
    }

    @Test func rulesFromANewerVersionAreNeverOverwritten() throws {
        let (model, harness) = try model()
        defer { harness.tearDown() }
        let newer = #"{"version":9,"rules":[]}"#
        harness.pluginSettings.set(newer, for: WindowsSettings.Key.appRules)
        #expect(model.rulesLocked)
        #expect(!model.addRule(bundleID: "com.example.a", .workspace(2)))
        #expect(model.addRule(bundleID: "com.example.a", .float))
        #expect(harness.pluginSettings.string(WindowsSettings.Key.appRules) == newer)
    }

    @Test func theChoiceTagsRoundTrip() {
        for choice in [WindowsConfigureModel.RuleChoice.float] + (1...9).map({ .workspace($0) }) {
            #expect(WindowsConfigureModel.RuleChoice(tag: choice.tag) == choice)
        }
        #expect(
            WindowsConfigureModel.RuleChoice(tag: "ws10") == nil && WindowsConfigureModel.RuleChoice(tag: "x") == nil)
    }
}
