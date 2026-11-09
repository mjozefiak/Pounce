import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// Assignment resolution and `assignments.json` (step 3.2): tables, defaults per orientation, duplicate display
/// UUIDs, hot-plug, versioning, the `.corrupt` copy, newer files.
@Suite struct ZoneAssignmentTests {
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }

    private func display(
        _ id: UInt32, _ uuid: String, x: CGFloat = 0, width: CGFloat = 1920, height: CGFloat = 1080
    ) -> DisplayInfo {
        DisplayInfo(
            id: id, uuid: uuid, frame: CGRect(x: x, y: 0, width: width, height: height), isMain: id == 1)
    }

    // MARK: Resolution

    @Test func aCellWithNoAssignmentUsesTheDefaultOfTheDisplayShape() {
        let config = ZonesConfig()
        let landscape = config.resolve(workspace: ws(1), displayKey: "A", orientation: .landscape)
        #expect(landscape.layout.id == StockLayouts.columns2)
        #expect(landscape.source == .defaultOfShape)
        #expect(!landscape.fellBack)
        let portrait = config.resolve(workspace: ws(1), displayKey: "A", orientation: .portrait)
        #expect(portrait.layout.id == StockLayouts.rows2)
    }

    @Test func theSettingsDefaultsReplaceTheBuiltInOnes() {
        var config = ZonesConfig()
        config.defaultLandscape = StockLayouts.grid2x2
        config.defaultPortrait = StockLayouts.focus
        #expect(config.resolve(workspace: ws(2), displayKey: "A", orientation: .landscape).layout.id == "stock.grid2x2")
        #expect(config.resolve(workspace: ws(2), displayKey: "A", orientation: .portrait).layout.id == "stock.focus")
    }

    @Test func theMostSpecificAssignmentWins() {
        var config = ZonesConfig()
        config.assignments.set(StockLayouts.columns3, workspace: ws(1), displayKey: DisplayKeys.landscape)
        config.assignments.set(StockLayouts.priority, workspace: ws(1), displayKey: "A")
        let own = config.resolve(workspace: ws(1), displayKey: "A", orientation: .landscape)
        #expect(own.layout.id == StockLayouts.priority)
        #expect(own.source == .assigned)
        let shape = config.resolve(workspace: ws(1), displayKey: "B", orientation: .landscape)
        #expect(shape.layout.id == StockLayouts.columns3)
        #expect(shape.source == .assignedForShape)
        // Another workspace and another shape are untouched.
        #expect(
            config.resolve(workspace: ws(2), displayKey: "A", orientation: .landscape).layout.id == "stock.columns2")
        #expect(config.resolve(workspace: ws(1), displayKey: "C", orientation: .portrait).layout.id == "stock.rows2")
    }

    @Test func aMissingLayoutFallsBackToTheNextChoiceAndIsReported() {
        var config = ZonesConfig()
        config.assignments.set("user.deleted", workspace: ws(3), displayKey: "A")
        let resolved = config.resolve(workspace: ws(3), displayKey: "A", orientation: .landscape)
        #expect(resolved.layout.id == StockLayouts.columns2)
        #expect(resolved.fellBack)
        #expect(resolved.source == .defaultOfShape)
        // A default that names a missing layout falls back to the built-in one.
        config.defaultLandscape = "user.gone"
        let builtIn = config.resolve(workspace: ws(4), displayKey: "A", orientation: .landscape)
        #expect(builtIn.layout.id == StockLayouts.columns2)
        #expect(builtIn.source == .builtIn)
        #expect(builtIn.fellBack)
    }

    @Test func aStockIdIsAlwaysValidAndAnInvalidLibraryLayoutIsSkipped() {
        var config = ZonesConfig()
        config.assignments.set(StockLayouts.focus, workspace: ws(1), displayKey: "A")
        #expect(!config.resolve(workspace: ws(1), displayKey: "A", orientation: .landscape).fellBack)
        let broken = GridLayout(id: "u1", name: "x", columns: [1, 1], rows: [1], zones: [])
        config.library = LayoutLibrary(StockLayouts.all + [broken])
        config.assignments.set("u1", workspace: ws(2), displayKey: "A")
        let resolved = config.resolve(workspace: ws(2), displayKey: "A", orientation: .landscape)
        #expect(resolved.fellBack)
        #expect(resolved.layout.id == StockLayouts.columns2)
    }

    @Test func aTableHoldsOneLayoutPerCellAndCountsUses() {
        var table = AssignmentTable()
        table.set("a", workspace: ws(1), displayKey: "A")
        table.set("b", workspace: ws(1), displayKey: "A")
        table.set("a", workspace: ws(2), displayKey: "A")
        #expect(table.entries.count == 2)
        #expect(table.layoutID(workspace: ws(1), displayKey: "A") == "b")
        #expect(table.count(using: "a") == 1)
        table.set(nil, workspace: ws(1), displayKey: "A")
        #expect(table.layoutID(workspace: ws(1), displayKey: "A") == nil)
    }

    // MARK: Display keys

    @Test func displaysWithDistinctUUIDsKeepThem() {
        let result = DisplayKeys.keys(for: [display(1, "A"), display(2, "B", x: 1920)])
        #expect(result.keys == [1: "A", 2: "B"])
        #expect(!result.hasDuplicates)
    }

    @Test func twoDisplaysWithOneUUIDAreToldApartByPosition() {
        // Listed right to left on purpose: the position decides, not the order of the list.
        let result = DisplayKeys.keys(for: [
            display(7, "SAME", x: 1920), display(3, "SAME", x: 0), display(9, "B", x: 3840),
        ])
        #expect(result.hasDuplicates)
        #expect(result.keys[3] == "SAME")
        #expect(result.keys[7] == "SAME#2")
        #expect(result.keys[9] == "B")
    }

    @Test func aReconnectedDisplayGetsItsAssignmentBack() {
        var config = ZonesConfig()
        config.assignments.set(StockLayouts.grid2x2, workspace: ws(1), displayKey: "STUDIO")
        // Unplugged: the workspace uses the display it moved to, with that display's own choice or default.
        #expect(
            config.resolve(workspace: ws(1), displayKey: "MACBOOK", orientation: .landscape).layout.id
                == "stock.columns2")
        // Plugged back in, possibly with another display id: the UUID is the key.
        let keys = DisplayKeys.keys(for: [display(12, "STUDIO")]).keys
        let key = keys[12] ?? ""
        #expect(config.resolve(workspace: ws(1), displayKey: key, orientation: .landscape).layout.id == "stock.grid2x2")
    }

    @Test func aDisplayShapeFollowsItsSize() {
        #expect(display(1, "A", width: 1080, height: 1920).orientation == .portrait)
        #expect(display(1, "A").orientation == .landscape)
    }

    // MARK: The store

    private func store(_ harness: WindowsHarness) -> AssignmentStore { AssignmentStore(directory: harness.directory) }

    @Test func aMissingFileStartsEmptyAndTheTableRoundTrips() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let first = store(harness)
        await first.load()
        #expect(await first.table.isEmpty)
        try await first.set(StockLayouts.priority, workspace: ws(2), displayKey: "A")
        try await first.set(StockLayouts.rows2, workspace: ws(1), displayKey: DisplayKeys.portrait)
        let second = store(harness)
        await second.load()
        #expect(await second.table.layoutID(workspace: ws(2), displayKey: "A") == StockLayouts.priority)
        #expect(await second.table.layoutID(workspace: ws(1), displayKey: DisplayKeys.portrait) == StockLayouts.rows2)
        let attributes = try FileManager.default.attributesOfItem(atPath: second.fileURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func clearingACellRemovesItFromTheFileAndApplyToWritesOnce() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let first = store(harness)
        await first.load()
        try await first.setAll([(ws(1), "A", "stock.focus"), (ws(2), "A", "stock.focus"), (ws(3), "A", "stock.rows2")])
        try await first.set(nil, workspace: ws(2), displayKey: "A")
        let second = store(harness)
        await second.load()
        #expect(await second.table.entries.count == 2)
        #expect(await second.table.layoutID(workspace: ws(2), displayKey: "A") == nil)
    }

    @Test func aCorruptFileIsSetAsideOnceAndTheTableStartsEmpty() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let url = harness.directory.appending(path: AssignmentStore.fileName)
        try Data("not json".utf8).write(to: url)
        let first = store(harness)
        await first.load()
        #expect(await first.table.isEmpty)
        #expect(await !first.isReadOnly)
        #expect(FileManager.default.fileExists(atPath: first.corruptURL.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // A second corrupt file replaces the one copy.
        try Data("{\"version\":0}".utf8).write(to: url)
        let second = store(harness)
        await second.load()
        let copy = try String(contentsOf: second.corruptURL, encoding: .utf8)
        #expect(copy.contains("\"version\":0"))
        // The store works again after that.
        try await second.set(StockLayouts.focus, workspace: ws(1), displayKey: "A")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aNewerFileIsReadAsWellAsPossibleAndNeverWritten() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let url = harness.directory.appending(path: AssignmentStore.fileName)
        let newer =
            #"{"version":2,"assignments":[{"workspace":1,"displayKey":"A","layoutID":"stock.focus"}],"extra":1}"#
        try Data(newer.utf8).write(to: url)
        let first = store(harness)
        await first.load()
        #expect(await first.isReadOnly)
        #expect(await first.table.layoutID(workspace: ws(1), displayKey: "A") == StockLayouts.focus)
        await #expect(throws: AssignmentStore.StoreError.readOnly) {
            try await first.set(StockLayouts.rows2, workspace: ws(1), displayKey: "A")
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == newer)
        #expect(!FileManager.default.fileExists(atPath: first.corruptURL.path))
    }

    @Test func entriesThatCannotBeUsedAreDroppedOnLoad() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let json = """
            {"version":1,"assignments":[
            {"workspace":0,"displayKey":"A","layoutID":"stock.focus"},
            {"workspace":10,"displayKey":"A","layoutID":"stock.focus"},
            {"workspace":1,"displayKey":"","layoutID":"stock.focus"},
            {"workspace":1,"displayKey":"A","layoutID":""},
            {"workspace":2,"displayKey":"A","layoutID":"stock.rows2"},
            {"workspace":2,"displayKey":"A","layoutID":"stock.focus"},
            {"workspace":3,"displayKey":"A","layoutID":"user.unknown"}]}
            """
        try Data(json.utf8).write(to: harness.directory.appending(path: AssignmentStore.fileName))
        let loaded = store(harness)
        await loaded.load()
        let table = await loaded.table
        #expect(table.entries.count == 2)
        #expect(table.layoutID(workspace: ws(2), displayKey: "A") == StockLayouts.rows2)
        // An unknown id is kept: it falls back when resolved and is reported, it is not lost.
        #expect(table.layoutID(workspace: ws(3), displayKey: "A") == "user.unknown")
    }

    @Test func anOlderFileGoesThroughTheMigrationSeam() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        // A made-up version 1 shape that version 2 renames: the seam turns it into the current shape.
        let old = #"{"version":1,"assignments":[{"workspace":1,"display":"A","layout":"stock.focus"}]}"#
        try Data(old.utf8).write(to: harness.directory.appending(path: AssignmentStore.fileName))
        let migrate: AssignmentStore.Migration = { data in
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return Data(
                text.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")
                    .replacingOccurrences(of: "\"display\"", with: "\"displayKey\"")
                    .replacingOccurrences(of: "\"layout\"", with: "\"layoutID\"").utf8)
        }
        let migrated = AssignmentStore(directory: harness.directory, currentVersion: 2, migrations: [1: migrate])
        await migrated.load()
        #expect(await migrated.table.layoutID(workspace: ws(1), displayKey: "A") == StockLayouts.focus)
        // Without the step the file cannot be read and is set aside, never silently dropped.
        let missing = AssignmentStore(directory: harness.directory, currentVersion: 2)
        await missing.load()
        #expect(await missing.table.isEmpty)
        #expect(FileManager.default.fileExists(atPath: missing.corruptURL.path))
    }

    @Test func theStoreWritesNoDisplayKeyToTheLog() async throws {
        // The file is the only place a display UUID lives; the store has no API that takes one for logging.
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "Sources/WindowsPlugin/Zones/AssignmentStore.swift"),
            encoding: .utf8)
        for line in source.split(separator: "\n") where line.contains("logger.") {
            #expect(!line.contains("displayKey") && !line.contains("layoutID"))
        }
    }

    // MARK: The settings

    @Test func theDefaultZoneLayoutsComeFromTheSettings() throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let settings = WindowsSettings(harness.pluginSettings)
        #expect(settings.defaultZoneLayout(for: .landscape) == StockLayouts.columns2)
        #expect(settings.defaultZoneLayout(for: .portrait) == StockLayouts.rows2)
        settings.setDefaultZoneLayout(StockLayouts.grid2x2, for: .landscape)
        settings.setDefaultZoneLayout(StockLayouts.focus, for: .portrait)
        #expect(settings.defaultZoneLayout(for: .landscape) == StockLayouts.grid2x2)
        #expect(settings.defaultZoneLayout(for: .portrait) == StockLayouts.focus)
        #expect(harness.store.keys.contains("plugins.windows.defaultZoneLayout.landscape"))
        settings.setDefaultZoneLayout("", for: .landscape)
        #expect(settings.defaultZoneLayout(for: .landscape) == StockLayouts.columns2)
    }
}
