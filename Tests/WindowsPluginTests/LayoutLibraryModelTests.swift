import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

@MainActor
private final class FakeFiles: LayoutFileAccess {
    var importURL: URL?
    var exportURL: URL?
    var suggested: [String] = []
    func chooseImport() -> URL? { importURL }
    func chooseExport(suggestedName: String) -> URL? {
        suggested.append(suggestedName)
        return exportURL
    }
}

@MainActor
private final class EditorLog {
    var opened: [(layout: GridLayout, isNew: Bool)] = []
    var onSaved: ((GridLayout) -> Void)?
}

/// The Layouts window as a library (step 4.3): the user's layouts, New, Duplicate, Rename, Edit, Delete with its
/// confirmation, Import with its summary, Export, the layout slots, and the pane's slot rows.
@Suite @MainActor struct LayoutLibraryModelTests {
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }

    private struct Rig {
        let plugin: WindowsPlugin
        let harness: WindowsHarness
        let model: LayoutsModel
        let files: FakeFiles
        let editor: EditorLog
    }

    private func rig(activate: Bool = true, library: String? = nil) async throws -> Rig {
        let harness = try WindowsHarness()
        if let library {
            try Data(library.utf8).write(to: harness.directory.appending(path: LayoutRepository.fileName))
        }
        let client = FakeWindowClient(
            displays: [FakeWindowClient.mainDisplay, FakeWindowClient.secondDisplay], windows: [makeWindow(1)])
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        if activate { try await plugin.activate() }
        let files = FakeFiles()
        let editor = EditorLog()
        let model = LayoutsModel(
            pane: plugin.paneModel, displays: { await client.displays() },
            openEditor: { layout, isNew, saved in
                editor.opened.append((layout, isNew))
                editor.onSaved = saved
            }, files: files)
        await model.refresh()
        return Rig(plugin: plugin, harness: harness, model: model, files: files, editor: editor)
    }

    private func finish(_ rig: Rig) async {
        await rig.plugin.deactivate()
        rig.harness.tearDown()
    }

    private func make(_ rig: Rig, _ name: String = "Mine") async throws -> GridLayout {
        var draft = LayoutsModel.newDraft()
        draft.name = name
        let created = try #require(await rig.plugin.runtime?.layouts.create(draft))
        await rig.model.refreshLibrary()
        return created
    }

    // MARK: Listing

    @Test func theLibraryListsStockThenTheUsersLayoutsFromTheFile() async throws {
        let seeded = """
            {"version":1,"layouts":[{"id":"user.a","name":"Coding","style":"grid","spacing":4,"grid":{"columns":[1,1],"rows":[1],"zones":[{"id":1,"colStart":0,"colEnd":1,"rowStart":0,"rowEnd":1},{"id":2,"colStart":1,"colEnd":2,"rowStart":0,"rowEnd":1}]}},{"id":"user.c","name":"Free","style":"canvas","spacing":0}]}
            """
        let rig = try await rig(library: seeded)
        defer { Task { await finish(rig) } }
        #expect(rig.model.userLayouts.map(\.name) == ["Coding"])
        #expect(rig.model.keptUntouched == 1)
        #expect(rig.model.library.layout("user.a") != nil)
        #expect(rig.model.library.layout("user.c") == nil)
        // A user's layout name is shown as it is, never looked up.
        #expect(rig.model.name(of: rig.model.userLayouts[0]) == "Coding")
        #expect(rig.model.rowDetail(of: rig.model.userLayouts[0]) == "Grid · 2 zones · Not assigned")
        #expect(rig.plugin.paneModel.layoutsSummary.hasPrefix("7 layouts"))
    }

    @Test func aPluginThatIsOffEditsNothing() async throws {
        let rig = try await rig(activate: false)
        defer { Task { await finish(rig) } }
        #expect(!rig.model.canEditLibrary)
        rig.model.newLayout()
        #expect(rig.editor.opened.isEmpty)
        await rig.model.duplicateSelected()
        #expect(rig.model.userLayouts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rig.harness.directory.appending(path: "layouts.json").path))
    }

    // MARK: New, edit, duplicate, rename

    @Test func newAndEditOpenTheEditorAndSelectWhatWasSaved() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        rig.model.newLayout()
        #expect(rig.editor.opened.count == 1)
        #expect(rig.editor.opened[0].isNew)
        #expect(rig.editor.opened[0].layout.zones.count == 1)
        let created = try await make(rig, "Coding")
        rig.editor.onSaved?(created)
        try await waitUntil { rig.model.selectedLayoutID == created.id }
        #expect(rig.model.selectedLayoutID == created.id)
        // Edit is for the user's layouts only.
        rig.model.selectedLayoutID = StockLayouts.focus
        rig.model.editSelected()
        #expect(rig.editor.opened.count == 1)
        rig.model.selectedLayoutID = created.id
        rig.model.editSelected()
        #expect(rig.editor.opened.count == 2)
        #expect(!rig.editor.opened[1].isNew)
        #expect(rig.editor.opened[1].layout.id == created.id)
    }

    @Test func duplicateMakesAnEditableCopyOfAStockLayoutAndSelectsIt() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        rig.model.selectedLayoutID = StockLayouts.priority
        await rig.model.duplicateSelected()
        let copy = try #require(rig.model.userLayouts.first)
        #expect(copy.name == "Priority 25/50/25 copy")
        #expect(rig.model.selectedLayoutID == copy.id)
        #expect(rig.model.canEditSelected)
        // The copy is in the library the engine uses.
        let library = await rig.plugin.runtime?.layouts.library
        #expect(library?.contains(copy.id) == true)
    }

    @Test func aLongNameStillDuplicates() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        let long = try await make(rig, String(repeating: "n", count: 64))
        rig.model.selectedLayoutID = long.id
        await rig.model.duplicateSelected()
        #expect(rig.model.userLayouts.count == 2)
        #expect(rig.model.userLayouts.allSatisfy { LayoutRules.isValidName($0.name) })
    }

    @Test func renameChangesOnlyTheNameOfAUserLayout() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        let mine = try await make(rig)
        rig.model.selectedLayoutID = mine.id
        await rig.model.renameSelected(to: "  Review ")
        #expect(rig.model.userLayouts.first?.name == "Review")
        #expect(rig.model.userLayouts.first?.id == mine.id)
        await rig.model.renameSelected(to: String(repeating: "x", count: 65))
        #expect(rig.model.userLayouts.first?.name == "Review")
        #expect(rig.model.notice != nil)
        rig.model.selectedLayoutID = StockLayouts.focus
        await rig.model.renameSelected(to: "Nope")
        #expect(StockLayouts.layout(StockLayouts.focus)?.name == "Focus")
    }

    // MARK: Delete

    @Test func deleteNamesTheAssignmentsThatFallBackAndGivesThemBack() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        let mine = try await make(rig, "Coding")
        await rig.model.setLayout(mine.id, workspace: ws(1), displayKey: "MAIN")
        await rig.model.setLayout(mine.id, workspace: ws(3), displayKey: "SECOND")
        await rig.model.setLayout(StockLayouts.focus, workspace: ws(2), displayKey: "MAIN")
        try await rig.model.setSlot(2, to: mine.id)
        rig.model.selectedLayoutID = mine.id
        rig.model.requestDelete()
        let deletion = try #require(rig.model.pendingDelete)
        #expect(deletion.cells.count == 2)
        #expect(deletion.cellNames == ["Workspace 1 on Main display", "Workspace 3 on Display 2"])
        #expect(deletion.name == "Coding")
        await rig.model.confirmDelete()
        #expect(rig.model.userLayouts.isEmpty)
        #expect(rig.model.table.layoutID(workspace: ws(1), displayKey: "MAIN") == nil)
        #expect(rig.model.table.layoutID(workspace: ws(2), displayKey: "MAIN") == StockLayouts.focus)
        #expect(rig.model.slots.isEmpty)
        #expect(rig.model.selectedLayoutID == StockLayouts.columns2)
        let stored = AssignmentStore(directory: rig.harness.directory)
        await stored.load()
        #expect(await stored.table.count(using: mine.id) == 0)
        // The cell now shows the display default.
        let display = try #require(rig.model.displays.first)
        #expect(rig.model.cell(workspace: ws(1), display: display).label == "Columns 2 · default")
    }

    @Test func deletingAnUnusedLayoutSaysNothingUsesIt() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        let mine = try await make(rig)
        rig.model.selectedLayoutID = mine.id
        rig.model.requestDelete()
        #expect(rig.model.pendingDelete?.cells.isEmpty == true)
        rig.model.pendingDelete = nil
        await rig.model.confirmDelete()
        #expect(rig.model.userLayouts.count == 1)
        // A stock layout cannot be deleted at all.
        rig.model.selectedLayoutID = StockLayouts.focus
        rig.model.requestDelete()
        #expect(rig.model.pendingDelete == nil)
    }

    @Test func cellsOfDisconnectedDisplaysAndShapesHaveWords() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        #expect(
            rig.model.cellName(workspace: ws(1), displayKey: "GONE") == "Workspace 1 on a display that is not connected"
        )
        #expect(
            rig.model.cellName(workspace: ws(2), displayKey: "landscape") == "Workspace 2 on every landscape display")
        #expect(rig.model.cellName(workspace: ws(2), displayKey: "portrait") == "Workspace 2 on every portrait display")
    }

    // MARK: Import and export

    private func write(_ rig: Rig, _ name: String, _ text: String) throws -> URL {
        let url = rig.harness.directory.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private let oneLayoutFile =
        #"{"version":1,"layouts":[{"id":"user.in","name":"Imported","style":"grid","spacing":4,"grid":{"columns":[1,1],"rows":[1],"zones":[{"id":1,"colStart":0,"colEnd":1,"rowStart":0,"rowEnd":1},{"id":2,"colStart":1,"colEnd":2,"rowStart":0,"rowEnd":1}]}}]}"#

    @Test func importShowsTheSummaryBeforeAnythingIsAdded() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        rig.files.importURL = try write(rig, "a.lintellayouts", oneLayoutFile)
        rig.model.beginImport()
        let preview = try #require(rig.model.pendingImport)
        #expect(preview.layouts.map(\.name) == ["Imported"])
        #expect(rig.model.userLayouts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rig.harness.directory.appending(path: "layouts.json").path))
        let lines = rig.model.importLines(preview)
        #expect(lines.first == "1 layouts will be added.")
        #expect(lines.last == "Assignments and layout slots are never imported.")
        await rig.model.confirmImport()
        #expect(rig.model.userLayouts.map(\.name) == ["Imported"])
        #expect(rig.model.selectedLayoutID == rig.model.userLayouts.first?.id)
        #expect(rig.model.pendingImport == nil)
    }

    @Test func cancellingAnImportAddsNothing() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        rig.model.loadImport(from: try write(rig, "a.lintellayouts", oneLayoutFile))
        #expect(rig.model.pendingImport != nil)
        rig.model.cancelImport()
        await rig.model.confirmImport()
        #expect(rig.model.userLayouts.isEmpty)
    }

    @Test func hostileFilesGiveAMessageAndNoPreview() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        for text in ["garbage", #"{"version":9,"layouts":[]}"#, #"{"version":1,"layouts":[{"name":"x"}]}"#] {
            rig.model.loadImport(from: try write(rig, "h.lintellayouts", text))
            // A file with only broken layouts has a preview with nothing to add; the others have none.
            if let preview = rig.model.pendingImport { #expect(preview.isEmpty) }
            rig.model.cancelImport()
        }
        rig.model.loadImport(from: try write(rig, "h.lintellayouts", "garbage"))
        #expect(rig.model.pendingImport == nil)
        #expect(rig.model.notice == "That file is not a Lintel layouts file.")
        // Too large: only the first megabyte is ever read.
        let big = rig.harness.directory.appending(path: "big.lintellayouts")
        try Data(repeating: 0x20, count: LayoutRules.maximumFileSize + 10).write(to: big)
        #expect(LayoutsModel.readLimited(big)?.count == LayoutRules.maximumFileSize + 1)
        rig.model.loadImport(from: big)
        #expect(rig.model.pendingImport == nil)
        #expect(rig.model.notice == LayoutsModel.text(for: .tooLarge))
        rig.model.loadImport(from: rig.harness.directory.appending(path: "missing.lintellayouts"))
        #expect(rig.model.pendingImport == nil)
    }

    @Test func importIsRefusedWhileThePluginIsOff() async throws {
        let rig = try await rig(activate: false)
        defer { Task { await finish(rig) } }
        rig.model.loadImport(from: try write(rig, "a.lintellayouts", oneLayoutFile))
        #expect(rig.model.pendingImport == nil)
        #expect(rig.model.notice != nil)
    }

    @Test func exportWritesTheSelectedLayoutAndAllOfMineWithoutSlots() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        let mine = try await make(rig, "Coding")
        try await rig.model.setSlot(1, to: mine.id)
        rig.files.exportURL = rig.harness.directory.appending(path: "out.lintellayouts")
        rig.model.selectedLayoutID = mine.id
        rig.model.export(.selected)
        #expect(rig.files.suggested == ["Coding"])
        let text = try String(contentsOf: try #require(rig.files.exportURL), encoding: .utf8)
        #expect(text.contains("\"Coding\"") && !text.contains("slots"))
        // The file imports back into another library.
        let preview = try LayoutImporter.inspect(Data(text.utf8), existingIDs: [])
        #expect(preview.layouts.count == 1 && preview.layouts[0].zones == mine.zones)
        rig.model.selectedLayoutID = StockLayouts.grid2x2
        rig.model.export(.selected)
        #expect(rig.files.suggested.last == "Grid 2×2")
        rig.model.export(.allMine)
        #expect(rig.files.suggested.last == "My layouts")
        // Cancelling the save panel writes nothing and says nothing.
        rig.files.exportURL = nil
        rig.model.export(.selected)
        #expect(rig.model.notice == nil)
    }

    // MARK: Slots

    @Test func slotsBindAndUnbindThroughTheWindowAndThePane() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        let mine = try await make(rig)
        try await rig.model.setSlot(3, to: mine.id)
        try await rig.model.setSlot(5, to: mine.id)
        #expect(rig.model.slots == [3: mine.id, 5: mine.id])
        #expect(rig.model.slots(of: mine.id) == [3, 5])
        #expect(rig.model.usageText(of: mine).contains("Slot 3, 5"))
        await rig.plugin.paneModel.setLayoutSlot(5, to: StockLayouts.focus)
        await rig.plugin.paneModel.setLayoutSlot(3, to: nil)
        await rig.model.refreshLibrary()
        #expect(rig.model.slots == [5: StockLayouts.focus])
        #expect(rig.plugin.paneModel.layoutSlots == [5: StockLayouts.focus])
        // The slot file survives a relaunch.
        let reread = LayoutRepository(directory: rig.harness.directory)
        await reread.load()
        #expect(await reread.slots == [5: StockLayouts.focus])
    }

    @Test func aNewerLibraryIsReadOnlyEverywhere() async throws {
        let rig = try await rig(library: #"{"version":2,"layouts":[]}"#)
        defer { Task { await finish(rig) } }
        #expect(rig.model.libraryLocked)
        #expect(!rig.model.canEditLibrary)
        rig.model.newLayout()
        #expect(rig.editor.opened.isEmpty)
        await rig.model.setSlot(1, to: StockLayouts.focus)
        #expect(rig.model.slots.isEmpty)
        await rig.plugin.paneModel.setLayoutSlot(1, to: StockLayouts.focus)
        #expect(rig.plugin.paneModel.layoutSlots.isEmpty)
    }

    @Test func theMatrixOffersTheUsersLayoutsAndTheDefaultsMayNameThem() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        let mine = try await make(rig, "Coding")
        await rig.model.setLayout(mine.id, workspace: ws(1), displayKey: "MAIN")
        let display = try #require(rig.model.displays.first)
        #expect(rig.model.cell(workspace: ws(1), display: display).label == "Coding")
        rig.plugin.paneModel.setDefaultZoneLayout(mine.id, for: .landscape)
        let other = try #require(rig.model.displays.last)
        #expect(rig.model.cell(workspace: ws(2), display: other).label == "Coding · default")
        #expect(rig.model.usageText(of: mine).contains("Default for landscape displays"))
        #expect(rig.plugin.paneModel.allLayouts.map(\.id).contains(mine.id))
    }

    @Test func anUnreadableFileIsNotReportedAsTooLarge() async throws {
        let rig = try await rig()
        defer { Task { await finish(rig) } }
        rig.model.loadImport(from: rig.harness.directory.appending(path: "missing.lintellayouts"))
        #expect(rig.model.notice == "That file could not be read.")
        #expect(rig.model.notice != LayoutsModel.text(for: .tooLarge))
        // A folder cannot be read either.
        rig.model.loadImport(from: rig.harness.directory)
        #expect(rig.model.notice == "That file could not be read.")
        #expect(rig.model.pendingImport == nil)
    }

    @Test func layoutsKeptUntouchedCountTowardTheImportLimit() async throws {
        let grid =
            #"{"name":"L","style":"grid","spacing":0,"grid":{"columns":[1],"rows":[1],"zones":[{"id":1,"colStart":0,"colEnd":1,"rowStart":0,"rowEnd":1}]},"id":"user.N"}"#
        var entries = (0..<255).map { grid.replacingOccurrences(of: "user.N", with: "user.\($0)") }
        entries.append(#"{"id":"user.canvas","name":"Free","style":"canvas","spacing":0}"#)
        let rig = try await rig(library: #"{"version":1,"layouts":[\#(entries.joined(separator: ","))]}"#)
        defer { Task { await finish(rig) } }
        #expect(rig.model.userLayouts.count == 255 && rig.model.keptUntouched == 1)
        rig.model.loadImport(from: try write(rig, "one.lintellayouts", oneLayoutFile))
        // 255 + 1 kept + 1 new is 257: the summary must refuse what adding would refuse.
        #expect(rig.model.pendingImport == nil)
        #expect(rig.model.notice == LayoutsModel.text(for: .tooManyLayouts))
    }
}
