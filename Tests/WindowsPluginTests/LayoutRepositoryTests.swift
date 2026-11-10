import Foundation
import Testing

@testable import WindowsPlugin

/// `layouts.json` and the layout library (step 4.1a): round trips, stable ids, stock templates read-only, delete in
/// use, corrupt and newer files, a layout of an unknown style surviving a save.
@Suite(.timeLimit(.minutes(1))) struct LayoutRepositoryTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "lintel-layouts-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func grid(_ name: String = "Mine") -> GridLayout {
        GridLayout(
            id: "", name: name, spacing: 4, columns: [1, 2], rows: [1],
            zones: [
                GridZone(id: 1, colStart: 0, colEnd: 1, rowStart: 0, rowEnd: 1),
                GridZone(id: 2, colStart: 1, colEnd: 2, rowStart: 0, rowEnd: 1),
            ])
    }

    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }

    @Test func aMissingFileIsAnEmptyLibraryWithTheStockTemplates() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LayoutRepository(directory: directory)
        await repository.load()
        #expect(await repository.userLayouts.isEmpty)
        #expect(await repository.library.layout(StockLayouts.columns2) != nil)
        #expect(await !repository.isReadOnly)
    }

    @Test func createdLayoutsGetStableUniqueIdsAndSurviveARoundTrip() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LayoutRepository(directory: directory)
        await repository.load()
        let first = try await repository.create(grid("One"))
        let second = try await repository.create(grid("Two"))
        #expect(first.id.hasPrefix("user."))
        #expect(first.id != second.id)
        let reopened = LayoutRepository(directory: directory)
        await reopened.load()
        #expect(await reopened.userLayouts == [first, second])
        let attributes = try FileManager.default.attributesOfItem(atPath: reopened.fileURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func aCallerCannotChooseTheIdOfANewLayout() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LayoutRepository(directory: directory)
        var draft = grid()
        draft.id = StockLayouts.columns2
        let created = try await repository.create(draft)
        #expect(created.id != StockLayouts.columns2)
        #expect(await repository.library.layout(StockLayouts.columns2)?.name == "Columns 2")
    }

    @Test func renameKeepsTheIdAndDuplicateMakesAnEditableCopyOfAStockLayout() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LayoutRepository(directory: directory)
        let mine = try await repository.create(grid("Mine"))
        try await repository.rename(mine.id, to: "  Renamed ")
        #expect(await repository.layout(mine.id)?.name == "Renamed")
        let copy = try await repository.duplicate(StockLayouts.priority, name: "Priority copy")
        #expect(copy.id != StockLayouts.priority)
        #expect(copy.zones == StockLayouts.layout(StockLayouts.priority)?.zones)
        try await repository.rename(copy.id, to: "Wide")
    }

    @Test func stockTemplatesAreReadOnly() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LayoutRepository(directory: directory)
        await #expect(throws: LayoutRepository.RepositoryError.stock) {
            try await repository.rename(StockLayouts.focus, to: "X")
        }
        await #expect(throws: LayoutRepository.RepositoryError.stock) {
            try await repository.replace(StockLayouts.all[0])
        }
        await #expect(throws: LayoutRepository.RepositoryError.stock) {
            try await repository.delete(StockLayouts.focus, assignments: AssignmentStore(directory: directory))
        }
        #expect(!FileManager.default.fileExists(atPath: repository.fileURL.path))
    }

    @Test func invalidLayoutsAndNamesAreRefused() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LayoutRepository(directory: directory)
        var broken = grid()
        broken.zones.removeLast()
        await #expect(throws: LayoutRepository.RepositoryError.invalid(.badGrid(.cellUncovered))) {
            try await repository.create(broken)
        }
        await #expect(throws: LayoutRepository.RepositoryError.invalid(.badName)) {
            try await repository.create(grid("  "))
        }
        await #expect(throws: LayoutRepository.RepositoryError.invalid(.badName)) {
            try await repository.create(grid(String(repeating: "a", count: 65)))
        }
        #expect(await repository.userLayouts.isEmpty)
    }

    @Test func deletingALayoutInUseGivesItsAssignmentsBackAndCountsThem() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LayoutRepository(directory: directory)
        let assignments = AssignmentStore(directory: directory)
        let mine = try await repository.create(grid())
        let other = try await repository.create(grid("Other"))
        try await assignments.set(mine.id, workspace: ws(1), displayKey: "A")
        try await assignments.set(mine.id, workspace: ws(2), displayKey: "B")
        try await assignments.set(other.id, workspace: ws(3), displayKey: "A")
        try await assignments.set(StockLayouts.focus, workspace: ws(4), displayKey: "A")
        try await repository.setSlot(3, to: mine.id)
        try await repository.setSlot(4, to: other.id)
        let changed = try await repository.delete(mine.id, assignments: assignments)
        #expect(changed == 2)
        let table = await assignments.table
        #expect(table.layoutID(workspace: ws(1), displayKey: "A") == nil)
        #expect(table.layoutID(workspace: ws(3), displayKey: "A") == other.id)
        #expect(table.layoutID(workspace: ws(4), displayKey: "A") == StockLayouts.focus)
        #expect(await repository.layout(mine.id) == nil)
        #expect(await repository.slots == [4: other.id])
        // The deleted layout resolves to the default now.
        let config = ZonesConfig(assignments: table, library: await repository.library)
        #expect(
            config.resolve(workspace: ws(1), displayKey: "A", orientation: .landscape).layout.id == "stock.columns2")
    }

    @Test func slotsBindToStockAndUserLayoutsAndCanBeFreed() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LayoutRepository(directory: directory)
        let mine = try await repository.create(grid())
        try await repository.setSlot(1, to: StockLayouts.grid2x2)
        try await repository.setSlot(9, to: mine.id)
        await #expect(throws: LayoutRepository.RepositoryError.notFound) {
            try await repository.setSlot(10, to: mine.id)
        }
        await #expect(throws: LayoutRepository.RepositoryError.notFound) {
            try await repository.setSlot(2, to: "user.none")
        }
        let reopened = LayoutRepository(directory: directory)
        await reopened.load()
        #expect(await reopened.slots == [1: StockLayouts.grid2x2, 9: mine.id])
        try await reopened.setSlot(1, to: nil)
        #expect(await reopened.slots == [9: mine.id])
    }

    @Test func aCorruptFileIsSetAsideOnceAndTheLibraryStartsEmpty() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: LayoutRepository.fileName)
        try Data("not json".utf8).write(to: url)
        let first = LayoutRepository(directory: directory)
        await first.load()
        #expect(await first.userLayouts.isEmpty)
        #expect(await !first.isReadOnly)
        #expect(FileManager.default.fileExists(atPath: first.corruptURL.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try Data("again".utf8).write(to: url)
        let second = LayoutRepository(directory: directory)
        await second.load()
        #expect(try String(contentsOf: second.corruptURL, encoding: .utf8) == "again")
        _ = try await second.create(grid())
    }

    @Test func aNewerFileIsReadAndNeverWritten() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: LayoutRepository.fileName)
        let newer = """
            {"version":2,"layouts":[{"id":"user.a","name":"A","style":"grid","spacing":0,"grid":{"columns":[1],"rows":[1],"zones":[{"id":1,"colStart":0,"colEnd":1,"rowStart":0,"rowEnd":1}]}}],"extra":true}
            """
        try Data(newer.utf8).write(to: url)
        let repository = LayoutRepository(directory: directory)
        await repository.load()
        #expect(await repository.isReadOnly)
        #expect(await repository.userLayouts.map(\.id) == ["user.a"])
        await #expect(throws: LayoutRepository.RepositoryError.readOnly) { try await repository.create(grid()) }
        #expect(try String(contentsOf: url, encoding: .utf8) == newer)
        #expect(!FileManager.default.fileExists(atPath: repository.corruptURL.path))
    }

    @Test func olderFilesGoThroughTheMigrationSeam() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: LayoutRepository.fileName)
        try Data(#"{"version":1,"layouts":[]}"#.utf8).write(to: url)
        let migrated = LayoutRepository(
            directory: directory, currentVersion: 2,
            migrations: [
                1: { data in
                    Data(
                        String(decoding: data, as: UTF8.self).replacingOccurrences(
                            of: "\"version\":1", with: "\"version\":2"
                        ).utf8)
                }
            ])
        await migrated.load()
        #expect(await !migrated.isReadOnly)
        _ = try await migrated.create(grid())
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"version\":2"))
        // Without a step the file cannot be read: it is set aside, not lost.
        let stuck = directory.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: true)
        try Data(#"{"version":1,"layouts":[]}"#.utf8).write(to: stuck.appending(path: LayoutRepository.fileName))
        let unmigrated = LayoutRepository(directory: stuck, currentVersion: 2)
        await unmigrated.load()
        #expect(FileManager.default.fileExists(atPath: unmigrated.corruptURL.path))
    }

    @Test func aLayoutOfAnUnknownStyleSurvivesASaveUntouchedAndIsNotOffered() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: LayoutRepository.fileName)
        let canvas =
            #"{"canvas":{"zones":[{"h":0.5,"w":0.5,"x":0.25,"y":0.1}]},"id":"user.canvas","name":"Free","spacing":2,"style":"canvas"}"#
        let broken =
            #"{"id":"user.broken","name":"Broken","spacing":2,"style":"grid","grid":{"columns":[1],"rows":[1],"zones":[]}}"#
        try Data(#"{"version":1,"layouts":[\#(canvas),\#(broken)]}"#.utf8).write(to: url)
        let repository = LayoutRepository(directory: directory)
        await repository.load()
        #expect(await repository.userLayouts.isEmpty)
        #expect(await repository.keptUntouchedCount == 2)
        #expect(await repository.library.layout("user.canvas") == nil)
        let mine = try await repository.create(grid())
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(canvas))
        #expect(text.contains("\"user.broken\""))
        let reopened = LayoutRepository(directory: directory)
        await reopened.load()
        #expect(await reopened.userLayouts == [mine])
        #expect(await reopened.keptUntouchedCount == 2)
        // A kept layout cannot be renamed, replaced or bound to a slot, and the id is never reused.
        await #expect(throws: LayoutRepository.RepositoryError.notFound) {
            try await reopened.rename("user.canvas", to: "X")
        }
        await #expect(throws: LayoutRepository.RepositoryError.notFound) {
            try await reopened.setSlot(1, to: "user.canvas")
        }
        // A kept layout that an assignment still names resolves to the default.
        var config = ZonesConfig(library: await reopened.library)
        config.assignments.set("user.canvas", workspace: ws(1), displayKey: "A")
        let resolved = config.resolve(workspace: ws(1), displayKey: "A", orientation: .landscape)
        #expect(resolved.fellBack)
    }

    @Test func atMostTwoHundredFiftySixLayoutsFit() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LayoutRepository(directory: directory)
        _ = try await repository.add((0..<256).map { _ in grid() })
        await #expect(throws: LayoutRepository.RepositoryError.limit) { try await repository.create(grid()) }
    }
}
