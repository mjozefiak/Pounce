import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// Window management v2, Phase 2: workspace names and the Configure model (shortcut list, workspace table, gaps).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ConfigureTests {
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }

    // MARK: Workspace names

    @Test func aNameIsCutToTwentyFourCharactersAndLosesControlAndBidiCharacters() {
        #expect(WorkspaceNames.clean("  Code  ") == "Code")
        #expect(WorkspaceNames.clean(String(repeating: "a", count: 40))?.count == 24)
        #expect(WorkspaceNames.clean("a\u{202E}b\u{0007}c\n") == "abc")
        #expect(WorkspaceNames.clean("\u{202E}\u{2066}  ") == nil)
        #expect(WorkspaceNames.clean("") == nil)
        // Letters of any script stay.
        #expect(WorkspaceNames.clean("Zażółć gęślą") == "Zażółć gęślą")
    }

    @Test func theStoredValueRoundTripsAndNamesNeedNotBeUnique() {
        var names = WorkspaceNames()
        names.set("Code", for: ws(1))
        names.set("Code", for: ws(3))
        let read = WorkspaceNames(json: names.json)
        #expect(read == names)
        #expect(read.name(of: ws(3)) == "Code" && read.label(of: ws(3)) == "3 · Code")
        #expect(read.label(of: ws(2)) == "2")
        names.set(nil, for: ws(1))
        names.set("", for: ws(3))
        #expect(names.json == "")
    }

    @Test func aDamagedOrNewerValueReadsAsNoNames() {
        #expect(WorkspaceNames(json: "not json").names.isEmpty)
        #expect(WorkspaceNames(json: #"{"version":1,"names":{"12":"x","0":"y","2":"ok"}}"#).names == [ws(2): "ok"])
        let newer = WorkspaceNames(json: #"{"version":9,"names":{"1":"x"}}"#)
        #expect(newer.names.isEmpty && newer.isReadOnly)
    }

    @Test func theStripNamesTheBoxInItsSpokenLabelAndNothingElse() {
        let summary = WorkspaceSummary(current: ws(3), visible: ["MAIN": ws(3)], counts: [ws(3): 4])
        var names = WorkspaceNames()
        names.set("Code", for: ws(3))
        let boxes = StripModel.boxes(summary: summary, workspaceCount: 4, occupiedOnly: false, names: names)
        #expect(StripModel.accessibilityLabel(boxes[2]) == "Workspace 3, Code, 4 windows")
        #expect(StripModel.accessibilityLabel(boxes[0]) == "Workspace 1, No windows")
        // The box itself is unchanged (nine boxes of 18 pt must fit).
        #expect(boxes.map(\.number) == [1, 2, 3, 4])
    }

    @Test func theHUDShowsTheNameAfterTheNumber() {
        #expect(WindowsHUDState.workspace(number: 3, windowCount: 1, name: "Code").title == "Workspace 3 · Code")
        #expect(WindowsHUDState.workspace(number: 3, windowCount: 1).title == "Workspace 3")
    }

    // MARK: The model

    private func rig() throws -> (WindowsPlugin, WindowsHarness, ShortcutLog, WindowsConfigureModel) {
        let harness = try WindowsHarness()
        let log = ShortcutLog()
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let context = PluginContext(
            storageDirectory: harness.directory, settings: harness.pluginSettings, usage: NoUsage(),
            logger: harness.context().logger, keychain: NoKeychain(), pasteboard: log, events: NoEvents(),
            workspace: NoWorkspace(), permissions: ScriptedPermissions(granted: true), clock: ContinuousClock(),
            windows: client, setCommandShortcut: { log.set($0, $1) }, commandShortcut: { log.get($0) })
        let plugin = WindowsPlugin(context: context, hud: RecordingHUD(), activationCenter: NotificationCenter())
        plugin.settings.setDefaultKind(.tiling)
        for command in plugin.commands { if let shortcut = command.defaultShortcut { log.set(command.id, shortcut) } }
        let pane = WindowsSettingsModel(
            context: context, settings: plugin.settings, registry: .standard, runtime: { nil },
            translate: { code, modifiers in modifiers.contains(.control) ? nil : (code == 40 ? "ķ" : nil) })
        let model = WindowsConfigureModel(pane: pane, commands: { plugin.commands })
        return (plugin, harness, log, model)
    }

    @Test func theNumberedFamiliesHaveNoRowsOfTheirOwnAndEveryOtherCommandHasOne() throws {
        let (plugin, harness, _, model) = try rig()
        defer { harness.tearDown() }
        let ids = Set(model.rows.map(\.id))
        #expect(!ids.contains(WindowsCommandID.workspace(1)) && !ids.contains(WindowsCommandID.moveToWorkspace(9)))
        #expect(ids.contains(WindowsCommandID.back) && ids.contains(WindowsCommandID.focus(.up)))
        #expect(ids.count == plugin.commands.count - 18)
        #expect(model.modifierFamilies == [.goToWorkspace, .moveToWorkspace])
    }

    @Test func rowsAreGroupedAndTheSearchNarrowsThemByEveryWord() throws {
        let (_, harness, _, model) = try rig()
        defer { harness.tearDown() }
        #expect(WindowsConfigureModel.group(of: WindowsCommandID.focus(.left)) == .focus)
        #expect(WindowsConfigureModel.group(of: WindowsCommandID.move(.up)) == .move)
        #expect(WindowsConfigureModel.group(of: WindowsCommandID.layoutAccordion) == .layout)
        #expect(WindowsConfigureModel.group(of: WindowsCommandID.grow) == .resize)
        #expect(WindowsConfigureModel.group(of: WindowsCommandID.moveToNextDisplay) == .display)
        #expect(WindowsConfigureModel.group(of: WindowsCommandID.back) == .workspaces)
        #expect(WindowsConfigureModel.group(of: WindowsCommandID.restoreAll) == .other)
        model.query = "focus right"
        #expect(model.visibleGroups == [.focus])
        #expect(model.rows(in: .focus).map(\.id) == [WindowsCommandID.focus(.right)])
        model.query = "no such command"
        #expect(model.visibleGroups.isEmpty)
        model.query = ""
        #expect(model.visibleGroups.count >= 5)
    }

    @Test func aCommandThatTypesACharacterIsFlaggedAndOneClickFixesOnlyThatCommand() throws {
        let (_, harness, log, model) = try rig()
        defer { harness.tearDown() }
        let right = try #require(model.rows.first { $0.id == WindowsCommandID.focus(.right) })
        #expect(right.typesCharacter)
        #expect(!(model.rows.first { $0.id == WindowsCommandID.focus(.left) }?.typesCharacter ?? true))
        model.useControlOption(for: right.id)
        #expect(log.get(right.id)?.modifiers == [.control, .option])
        #expect(model.rows.first { $0.id == right.id }?.typesCharacter == false)
        #expect(log.get(WindowsCommandID.focus(.left))?.modifiers == [.option])
    }

    @Test func twoCommandsOnOneShortcutAreShownAsAConflictAndReplaceFreesTheOther() throws {
        let (_, harness, log, model) = try rig()
        defer { harness.tearDown() }
        #expect(model.rows.allSatisfy { $0.conflict == nil })
        log.set(WindowsCommandID.toggleLayout, KeyShortcut(key: "/", modifiers: [.option]))
        model.refresh()
        let tiles = try #require(model.rows.first { $0.id == WindowsCommandID.layoutTiles })
        let toggle = try #require(model.rows.first { $0.id == WindowsCommandID.toggleLayout })
        #expect(tiles.conflict == toggle.title && toggle.conflict == tiles.title)
        model.replaceConflict(of: WindowsCommandID.toggleLayout)
        #expect(log.get(WindowsCommandID.layoutTiles) == nil)
        #expect(log.get(WindowsCommandID.toggleLayout) == KeyShortcut(key: "/", modifiers: [.option]))
        #expect(model.rows.allSatisfy { $0.conflict == nil })
    }

    @Test func resetPutsOneShortcutBackAndTakesItFromAnyoneWhoHoldsIt() throws {
        let (_, harness, log, model) = try rig()
        defer { harness.tearDown() }
        log.set(WindowsCommandID.layoutTiles, nil)
        log.set(WindowsCommandID.toggleLayout, KeyShortcut(key: "/", modifiers: [.option]))
        model.refresh()
        model.reset(WindowsCommandID.layoutTiles)
        #expect(log.get(WindowsCommandID.layoutTiles) == KeyShortcut(key: "/", modifiers: [.option]))
        #expect(log.get(WindowsCommandID.toggleLayout) == nil)
    }

    @Test func resetAllRestoresTheDefaultsWithOneOwnerPerKey() throws {
        let (plugin, harness, log, model) = try rig()
        defer { harness.tearDown() }
        log.set(WindowsCommandID.focus(.left), KeyShortcut(key: "x", modifiers: [.command]))
        log.set(WindowsCommandID.toggleLayout, KeyShortcut(key: "/", modifiers: [.option]))
        log.set(WindowsCommandID.focus(.up), KeyShortcut(key: "j", modifiers: [.option]))
        model.refresh()
        model.resetAll()
        for command in plugin.commands { #expect(log.get(command.id) == command.defaultShortcut, "\(command.id)") }
        #expect(model.rows.allSatisfy { $0.conflict == nil && $0.isDefault })
    }

    @Test func aNameIsStoredCleanedAndNeverOverwritesANewerValue() throws {
        let (_, harness, _, model) = try rig()
        defer { harness.tearDown() }
        model.setName("  Code ", for: ws(1))
        #expect(model.name(of: ws(1)) == "Code")
        #expect(WindowsSettings(harness.pluginSettings).workspaceNames.name(of: ws(1)) == "Code")
        model.setName("", for: ws(1))
        #expect(harness.pluginSettings.string(WindowsSettings.Key.workspaceNames) == "")
        let newer = #"{"version":9,"names":{}}"#
        harness.pluginSettings.set(newer, for: WindowsSettings.Key.workspaceNames)
        model.refresh()
        #expect(model.namesLocked)
        model.setName("x", for: ws(2))
        #expect(harness.pluginSettings.string(WindowsSettings.Key.workspaceNames) == newer)
    }

    @Test func theWorkspaceTableShowsTheEffectiveGapsAndKindAndWritesOverrides() throws {
        let (_, harness, _, model) = try rig()
        defer { harness.tearDown() }
        #expect(model.workspaces.count == 9)
        #expect(model.gapsSummary(of: ws(1)) == "Default · 10 pt")
        #expect(model.kindChoice(of: ws(1)) == WindowsSettingsModel.useDefaultChoice)
        model.setGaps(0, for: ws(1))
        #expect(model.gapsSummary(of: ws(1)) == "0 pt" && model.gapsValue(of: ws(1)) == 0)
        model.setGaps(nil, for: ws(1))
        #expect(model.gapsSummary(of: ws(1)) == "Default · 10 pt")
        model.pane.setOverrideKind(.accordion, for: ws(2))
        #expect(model.orientationOption(of: ws(2))?.id == AccordionStrategy.orientationID)
        #expect(model.orientationOption(of: ws(1))?.id == TilingStrategy.rootOrientationID)
        model.setOrientation("vertical", for: ws(2))
        #expect(model.orientationChoice(of: ws(2)) == "vertical")
        model.setOrientation(WindowsSettingsModel.useDefaultChoice, for: ws(2))
        #expect(model.orientationChoice(of: ws(2)) == WindowsSettingsModel.useDefaultChoice)
        model.pane.setOverrideKind(.free, for: ws(3))
        #expect(model.orientationOption(of: ws(3)) == nil)
    }

    @Test func theGlobalValuesAreTheGapsThePaddingAndTheResizeStep() throws {
        let (_, harness, _, model) = try rig()
        defer { harness.tearDown() }
        let ids = Set(model.globalOptions.map(\.id))
        #expect(
            ids == [
                TilingStrategy.innerGapID, TilingStrategy.outerGapID, TilingStrategy.resizeStepID,
                AccordionStrategy.paddingID,
            ])
        #expect(
            model.summary
                == "9 workspaces · \(model.shortcutCount) shortcuts · \(WindowsSettings.defaultFloatingApps.count) rules"
        )
    }
}
