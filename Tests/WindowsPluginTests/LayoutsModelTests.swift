import CoreGraphics
import Foundation
import LintelKit
import SwiftUI
import Testing

@testable import WindowsPlugin

/// The Layouts window's model (step 3.6): the matrix, effective-layout labels, *Apply to…*, *Identify*, the kind
/// of each workspace, the keyboard table and the Settings rows.
@Suite(.timeLimit(.minutes(1))) @MainActor struct LayoutsModelTests {
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }

    private struct Rig {
        let plugin: WindowsPlugin
        let harness: WindowsHarness
        let model: LayoutsModel
        let identified: IdentifyLog
    }

    @MainActor
    final class IdentifyLog {
        var numbers: [Int] = []
    }

    private func rig(
        activate: Bool = true,
        displays: [DisplayInfo] = [FakeWindowClient.mainDisplay, FakeWindowClient.secondDisplay],
        seed: String? = nil
    ) async throws -> Rig {
        let harness = try WindowsHarness()
        if let seed { try Data(seed.utf8).write(to: harness.directory.appending(path: AssignmentStore.fileName)) }
        let client = FakeWindowClient(displays: displays, windows: [makeWindow(1)])
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        if activate { try await plugin.activate() }
        let log = IdentifyLog()
        let model = LayoutsModel(
            pane: plugin.paneModel, displays: { await client.displays() }, identify: { log.numbers.append($0.number) })
        await model.refresh()
        return Rig(plugin: plugin, harness: harness, model: model, identified: log)
    }

    private func finish(_ rig: Rig) async {
        await rig.plugin.deactivate()
        rig.harness.tearDown()
    }

    private func storedTable(_ rig: Rig) async -> AssignmentTable {
        let store = AssignmentStore(directory: rig.harness.directory)
        await store.load()
        return await store.table
    }

    // MARK: Displays and labels

    @Test func theMatrixColumnsAreTheDisplaysMainFirst() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        let displays = rig.model.displays
        #expect(displays.map(\.key) == ["MAIN", "SECOND"])
        #expect(displays.map(\.number) == [1, 2])
        #expect(displays.map(\.title) == ["Main display", "Display 2"])
        #expect(displays.first?.detail == "1920 × 1080")
        #expect(rig.model.workspaces.count == 4)
        #expect(!rig.model.hasDuplicateDisplays)
    }

    @Test func anEmptyCellSaysWhichLayoutAppliesAndWhy() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        let display = try #require(rig.model.displays.first)
        let cell = rig.model.cell(workspace: ws(1), display: display)
        #expect(cell.label == "Columns 2 · default")
        #expect(cell.assignedID == nil)
        #expect(cell.effective.layout.id == StockLayouts.columns2)
        #expect(rig.model.defaultTitle(for: display) == "Use default (Columns 2)")
    }

    @Test func anAssignedCellShowsTheLayoutAndIsStored() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        let display = try #require(rig.model.displays.first)
        await rig.model.setLayout(StockLayouts.grid2x2, workspace: ws(2), displayKey: display.key)
        let cell = rig.model.cell(workspace: ws(2), display: display)
        #expect(cell.label == "Grid 2×2")
        #expect(cell.assignedID == StockLayouts.grid2x2)
        #expect(await storedTable(rig).layoutID(workspace: ws(2), displayKey: "MAIN") == StockLayouts.grid2x2)
        // The other cells are untouched.
        #expect(rig.model.cell(workspace: ws(1), display: display).assignedID == nil)
        await rig.model.setLayout(nil, workspace: ws(2), displayKey: display.key)
        #expect(rig.model.cell(workspace: ws(2), display: display).label == "Columns 2 · default")
        #expect(await storedTable(rig).isEmpty)
    }

    @Test func theDefaultsFollowTheSettingsAndTheDisplayShape() async throws {
        let tall = DisplayInfo(
            id: 3, uuid: "TALL", frame: CGRect(x: 4000, y: 0, width: 1000, height: 2000), isMain: false)
        let rig = try await rig(displays: [FakeWindowClient.mainDisplay, tall])
        defer { Task { await finish(rig) } }
        let wide = try #require(rig.model.displays.first)
        let portrait = try #require(rig.model.displays.last)
        #expect(rig.model.cell(workspace: ws(1), display: portrait).label == "Rows 2 · default")
        rig.plugin.paneModel.setDefaultZoneLayout(StockLayouts.priority, for: .landscape)
        #expect(rig.model.cell(workspace: ws(1), display: wide).label == "Priority 25/50/25 · default")
        #expect(rig.model.cell(workspace: ws(1), display: portrait).label == "Rows 2 · default")
        #expect(rig.model.defaultTitle(for: wide) == "Use default (Priority 25/50/25)")
    }

    @Test func aMissingLayoutIsReportedAndUsesTheDefault() async throws {
        let seed = #"{"version":1,"assignments":[{"workspace":1,"displayKey":"MAIN","layoutID":"user.gone"}]}"#
        let rig = try await rig(seed: seed)
        defer { Task { await finish(rig) } }
        let display = try #require(rig.model.displays.first)
        let cell = rig.model.cell(workspace: ws(1), display: display)
        #expect(cell.effective.fellBack)
        #expect(cell.label == "Columns 2 · default")
        #expect(rig.model.fallbackCount == 1)
    }

    @Test func twoDisplaysWithOneUUIDAreTolldApartAndTheWindowSaysSo() async throws {
        let first = DisplayInfo(id: 1, uuid: "SAME", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), isMain: true)
        let second = DisplayInfo(id: 2, uuid: "SAME", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        let rig = try await rig(displays: [second, first])
        defer { Task { await finish(rig) } }
        #expect(rig.model.hasDuplicateDisplays)
        #expect(rig.model.displays.map(\.key) == ["SAME", "SAME#2"])
        await rig.model.setLayout(StockLayouts.focus, workspace: ws(1), displayKey: "SAME#2")
        let table = await storedTable(rig)
        #expect(table.layoutID(workspace: ws(1), displayKey: "SAME#2") == StockLayouts.focus)
        #expect(table.layoutID(workspace: ws(1), displayKey: "SAME") == nil)
    }

    // MARK: Apply to…

    @Test func applyToWritesTheChosenCells() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        await rig.model.apply(StockLayouts.columns3, to: .display("SECOND"))
        var table = await storedTable(rig)
        #expect(table.entries.count == 4)
        #expect(table.entries.allSatisfy { $0.displayKey == "SECOND" && $0.layoutID == StockLayouts.columns3 })
        await rig.model.apply(StockLayouts.rows2, to: .workspace(ws(3)))
        table = await storedTable(rig)
        #expect(table.layoutID(workspace: ws(3), displayKey: "MAIN") == StockLayouts.rows2)
        #expect(table.layoutID(workspace: ws(3), displayKey: "SECOND") == StockLayouts.rows2)
        await rig.model.apply(StockLayouts.focus, to: .everything)
        table = await storedTable(rig)
        #expect(table.entries.count == 8)
        #expect(table.entries.allSatisfy { $0.layoutID == StockLayouts.focus })
        #expect(rig.model.usage(of: StockLayouts.focus) == 8)
        #expect(rig.model.usageText(of: rig.model.selectedLayout) == "Not assigned · Default for landscape displays")
    }

    @Test func theDetailCardCountsCellsAndNamesDefaults() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        let columns2 = try #require(StockLayouts.layout(StockLayouts.columns2))
        let rows2 = try #require(StockLayouts.layout(StockLayouts.rows2))
        let focus = try #require(StockLayouts.layout(StockLayouts.focus))
        #expect(rig.model.usageText(of: columns2) == "Not assigned · Default for landscape displays")
        #expect(rig.model.usageText(of: rows2) == "Not assigned · Default for portrait displays")
        await rig.model.apply(StockLayouts.focus, to: .workspace(ws(1)))
        #expect(rig.model.usageText(of: focus) == "Used on 2 cells")
        #expect(rig.model.detail(of: StockLayouts.all[4]) == "Grid · 4 zones")
    }

    @Test func aFailedWriteIsReportedNotOnlyLogged() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        let url = rig.harness.directory
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        await rig.model.setLayout(StockLayouts.focus, workspace: ws(1), displayKey: "MAIN")
        #expect(rig.model.writeFailed)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        await rig.model.setLayout(StockLayouts.focus, workspace: ws(1), displayKey: "MAIN")
        #expect(!rig.model.writeFailed)
    }

    // MARK: Off, locked

    @Test func aPluginThatIsOffCanNotBeEdited() async throws {
        let rig = try await rig(activate: false)
        defer { rig.harness.tearDown() }
        #expect(!rig.model.isActive)
        #expect(!rig.model.canEdit)
        let display = try #require(rig.model.displays.first)
        await rig.model.setLayout(StockLayouts.focus, workspace: ws(1), displayKey: display.key)
        await rig.model.apply(StockLayouts.focus, to: .everything)
        #expect(!FileManager.default.fileExists(atPath: rig.harness.directory.appending(path: "assignments.json").path))
    }

    @Test func aFileFromANewerVersionIsNeverWritten() async throws {
        let newer = #"{"version":9,"assignments":[]}"#
        let rig = try await rig(seed: newer)
        defer { Task { await finish(rig) } }
        #expect(rig.model.isLocked)
        #expect(!rig.model.canEdit)
        await rig.model.setLayout(StockLayouts.focus, workspace: ws(1), displayKey: "MAIN")
        let text = try String(
            contentsOf: rig.harness.directory.appending(path: "assignments.json"), encoding: .utf8)
        #expect(text == newer)
    }

    // MARK: Kind per workspace

    @Test func theKindOfAWorkspaceIsAnOverrideThatDisappearsWhenItEqualsTheDefault() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        let settings = WindowsSettings(rig.harness.pluginSettings)
        // The harness default kind is Free.
        #expect(rig.model.kind(of: ws(2)) == .free)
        rig.model.setKind(.zones, for: ws(2))
        #expect(rig.model.kind(of: ws(2)) == .zones)
        #expect(settings.workspaceOverrides.byWorkspace[ws(2)]?.kind == .zones)
        let display = try #require(rig.model.displays.first)
        #expect(rig.model.cell(workspace: ws(2), display: display).isInactive == false)
        #expect(rig.model.cell(workspace: ws(1), display: display).isInactive)
        rig.model.setKind(.free, for: ws(2))
        #expect(settings.workspaceOverrides.byWorkspace[ws(2)] == nil)
        #expect(rig.model.pane.selectableKinds == [.tiling, .zones, .free])
    }

    // MARK: Identify

    @Test func identifyNamesTheDisplayByItsNumber() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        let second = try #require(rig.model.displays.last)
        rig.model.identify(second)
        #expect(rig.identified.numbers == [2])
    }

    // MARK: The keyboard table

    struct KeyCase: Sendable, CustomTestStringConvertible {
        var name: String
        var keys: [MatrixKey]
        var focus: MatrixPosition
        var assigned: [Int: String]
        var testDescription: String { name }
    }

    nonisolated static let table: [KeyCase] = [
        KeyCase(name: "starts at the first cell", keys: [], focus: MatrixPosition(row: 0, column: 0), assigned: [:]),
        KeyCase(name: "right", keys: [.right], focus: MatrixPosition(row: 0, column: 1), assigned: [:]),
        KeyCase(
            name: "right stops at the edge", keys: [.right, .right], focus: MatrixPosition(row: 0, column: 1),
            assigned: [:]),
        KeyCase(name: "down twice", keys: [.down, .down], focus: MatrixPosition(row: 2, column: 0), assigned: [:]),
        KeyCase(name: "up stops at the top", keys: [.up], focus: MatrixPosition(row: 0, column: 0), assigned: [:]),
        KeyCase(name: "left stops at the edge", keys: [.left], focus: MatrixPosition(row: 0, column: 0), assigned: [:]),
        KeyCase(
            name: "down stops at the last workspace", keys: Array(repeating: .down, count: 9),
            focus: MatrixPosition(row: 3, column: 0), assigned: [:]),
        KeyCase(
            name: "3 picks Columns 3", keys: [.layout(3)], focus: MatrixPosition(row: 0, column: 0),
            assigned: [1: StockLayouts.columns3]),
        KeyCase(
            name: "6 picks Priority on the second display", keys: [.right, .down, .layout(6)],
            focus: MatrixPosition(row: 1, column: 1), assigned: [2: StockLayouts.priority]),
        KeyCase(
            name: "7 is no layout", keys: [.layout(7), .layout(0)], focus: MatrixPosition(row: 0, column: 0),
            assigned: [:]),
        KeyCase(
            name: "delete gives the cell back", keys: [.layout(2), .clear], focus: MatrixPosition(row: 0, column: 0),
            assigned: [:]),
    ]

    @Test(arguments: table)
    func eachKeySequenceMovesAndChangesTheMatrix(_ item: KeyCase) async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        for key in item.keys { await rig.model.handle(key) }
        #expect(rig.model.focused == item.focus)
        let table = await storedTable(rig)
        #expect(table.entries.count == item.assigned.count)
        for (workspace, layout) in item.assigned {
            let key = rig.model.displays[item.focus.column].key
            #expect(table.layoutID(workspace: ws(workspace), displayKey: key) == layout)
        }
    }

    // MARK: Settings rows

    @Test func theSummaryCountsLayoutsAndZonesWorkspaces() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        #expect(rig.model.summary == "6 layouts · Zones: no workspaces")
        rig.model.setKind(.zones, for: ws(1))
        rig.model.setKind(.zones, for: ws(3))
        #expect(rig.model.summary == "6 layouts · Zones: 2 workspaces")
    }

    @Test func theDefaultZoneLayoutRowsWriteTheSettingsAndTheEngineFollows() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        let pane = rig.plugin.paneModel
        #expect(pane.defaultZoneLayout(for: .landscape) == StockLayouts.columns2)
        pane.setDefaultZoneLayout(StockLayouts.columns3, for: .landscape)
        pane.setDefaultZoneLayout(StockLayouts.focus, for: .portrait)
        #expect(pane.defaultZoneLayout(for: .landscape) == StockLayouts.columns3)
        let settings = WindowsSettings(rig.harness.pluginSettings)
        #expect(settings.defaultZoneLayout(for: .portrait) == StockLayouts.focus)
        #expect(rig.model.zonesConfig.defaultLandscape == StockLayouts.columns3)
    }

    /// QA: arrows and ⌫ did not respond on a real desktop (only a digit did). The model's reaction to each key is
    /// tested above; this pins the view's table from a pressed key to that key, arrows and delete included.
    @Test func theViewsKeyTableMapsArrowsDeleteAndDigitsAndIgnoresModifiedKeys() {
        func key(_ key: KeyEquivalent, _ characters: String = "", _ modifiers: EventModifiers = []) -> MatrixKey? {
            LayoutsWindowView.matrixKey(key: key, characters: characters, modifiers: modifiers)
        }
        #expect(key(.leftArrow) == .left && key(.rightArrow) == .right)
        #expect(key(.upArrow) == .up && key(.downArrow) == .down)
        #expect(key(.delete) == .clear && key(.deleteForward) == .clear)
        #expect(key(KeyEquivalent("3"), "3") == .layout(3))
        #expect(key(KeyEquivalent("3"), "3", .command) == nil)
        #expect(key(KeyEquivalent("x"), "x") == nil)
    }

    /// Round 13 B1: Backspace did nothing in the matrix and the editor while forward delete worked. The physical keys
    /// are matched by their characters too (U+007F Backspace, U+0008, U+F728 forward delete), in both key tables.
    @Test func everyDeleteKeyAndItsCharacterMeansDeleteInTheMatrixAndTheEditor() {
        let backspace = KeyEquivalent("\u{7F}")
        let cases: [(KeyEquivalent, String)] = [
            (.delete, ""), (.deleteForward, ""), (backspace, "\u{7F}"), (KeyEquivalent("x"), "\u{8}"),
            (KeyEquivalent("x"), "\u{F728}"),
        ]
        for (key, characters) in cases {
            #expect(
                LayoutsWindowView.matrixKey(key: key, characters: characters, modifiers: []) == .clear,
                "matrix \(characters.unicodeScalars.map(\.value))")
            #expect(
                GridEditorView.editorKey(key: key, characters: characters, modifiers: []) == .delete,
                "editor \(characters.unicodeScalars.map(\.value))")
        }
        // A plain letter or a modified delete is not one.
        #expect(LayoutsWindowView.matrixKey(key: KeyEquivalent("x"), characters: "x", modifiers: []) == nil)
        #expect(GridEditorView.editorKey(key: .delete, characters: "\u{7F}", modifiers: .command) == nil)
    }
}
