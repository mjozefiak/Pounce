import Foundation
import Testing

@testable import WindowsPlugin

/// `.lintellayouts` import and export (step 4.1b): the shared validator, hostile files, colliding ids, the summary
/// before anything is added.
@Suite(.timeLimit(.minutes(1))) struct LayoutImporterTests {
    private func layoutJSON(
        id: String = "user.x", name: String = "X", style: String = "grid", columns: String = "[1,1]",
        rows: String = "[1]", zones: String? = nil, extra: String = ""
    ) -> String {
        let zones =
            zones
            ?? #"[{"id":1,"colStart":0,"colEnd":1,"rowStart":0,"rowEnd":1},{"id":2,"colStart":1,"colEnd":2,"rowStart":0,"rowEnd":1}]"#
        return
            #"{"id":"\#(id)","name":"\#(name)","style":"\#(style)","spacing":4,"grid":{"columns":\#(columns),"rows":\#(rows),"zones":\#(zones)}\#(extra)}"#
    }

    private func file(_ layouts: [String], version: Int = 1, extra: String = "") -> Data {
        Data(#"{"version":\#(version),"layouts":[\#(layouts.joined(separator: ","))]\#(extra)}"#.utf8)
    }

    private func inspect(_ data: Data, existing: Set<String> = [], count: Int = 0) throws -> ImportPreview {
        try LayoutImporter.inspect(data, existingIDs: existing, existingCount: count)
    }

    @Test func aValidFileGivesASummaryOfWhatWouldBeAdded() throws {
        let preview = try inspect(file([layoutJSON(id: "user.a", name: "A"), layoutJSON(id: "user.b", name: "B")]))
        #expect(preview.layouts.map(\.name) == ["A", "B"])
        #expect(preview.layouts.map(\.id) == ["user.a", "user.b"])
        #expect(preview.regeneratedIDs == 0 && preview.rejected == 0 && preview.skippedUnknownStyle == 0)
    }

    @Test func collidingIdsAreRegeneratedAndStockIdsToo() throws {
        let data = file([
            layoutJSON(id: "user.a"), layoutJSON(id: "user.a", name: "Again"), layoutJSON(id: "stock.focus"),
            layoutJSON(id: "user.mine"),
        ])
        let preview = try inspect(data, existing: ["user.mine"])
        #expect(preview.layouts.count == 4)
        #expect(Set(preview.layouts.map(\.id)).count == 4)
        #expect(preview.layouts[0].id == "user.a")
        #expect(preview.regeneratedIDs == 3)
        #expect(preview.layouts.allSatisfy { LayoutRules.isValidUserID($0.id) })
    }

    @Test func slotsAndAssignmentsInAFileAreNeverImported() async throws {
        let data = file(
            [layoutJSON()],
            extra: #","slots":{"1":"user.x"},"assignments":[{"workspace":1,"displayKey":"A","layoutID":"user.x"}]"#)
        let preview = try inspect(data)
        #expect(preview.layouts.count == 1)
        let directory = FileManager.default.temporaryDirectory.appending(path: "lintel-imp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LayoutRepository(directory: directory)
        // Nothing is written by looking at the file.
        #expect(!FileManager.default.fileExists(atPath: repository.fileURL.path))
        try await repository.add(preview.layouts)
        #expect(await repository.slots.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "assignments.json").path))
    }

    @Test func layoutsOfAnotherStyleAndBrokenOnesAreCountedNotImported() throws {
        let data = file([
            layoutJSON(id: "user.canvas", style: "canvas"), layoutJSON(zones: "[]"), layoutJSON(name: "Fine"),
            #"{"nonsense":true}"#,
        ])
        let preview = try inspect(data)
        #expect(preview.layouts.map(\.name) == ["Fine"])
        #expect(preview.skippedUnknownStyle == 1)
        #expect(preview.rejected == 2)
    }

    // MARK: Hostile files

    @Test func nonFiniteAndHugeNumbersAreRefused() throws {
        for columns in ["[NaN,1]", "[Infinity,1]", "[-Infinity,1]"] {
            #expect(throws: ImportError.malformed) { try inspect(file([layoutJSON(columns: columns)])) }
        }
        // Out-of-range and unreasonable weights never reach a layout.
        for columns in ["[1e999,1]", "[1e300,1e300]", "[0,1]", "[-1,1]"] {
            let outcome = try? inspect(file([layoutJSON(columns: columns)]))
            #expect(outcome == nil || outcome?.layouts.isEmpty == true)
        }
    }

    @Test func aFileOverOneMegabyteIsRefusedBeforeParsing() {
        let padding = String(repeating: " ", count: LayoutRules.maximumFileSize)
        #expect(throws: ImportError.tooLarge) { try inspect(Data((#"{"version":1,"layouts":[]}"# + padding).utf8)) }
    }

    @Test func moreThanTwoHundredFiftySixLayoutsAreRefused() throws {
        let many = (0..<257).map { layoutJSON(id: "user.\($0)") }
        #expect(throws: ImportError.tooManyLayouts) { try inspect(file(many)) }
        let ok = (0..<256).map { layoutJSON(id: "user.\($0)") }
        #expect(try inspect(file(ok)).layouts.count == 256)
        // The library counts too.
        #expect(throws: ImportError.tooManyLayouts) { try inspect(file(ok), count: 1) }
    }

    @Test func tooManyZonesAndTooManyTracksAreRejected() throws {
        let columns = "[" + Array(repeating: "1", count: 8).joined(separator: ",") + "]"
        let rows = "[" + Array(repeating: "1", count: 9).joined(separator: ",") + "]"
        var cells: [String] = []
        for row in 0..<9 {
            for column in 0..<8 {
                cells.append(
                    #"{"id":\#(cells.count + 1),"colStart":\#(column),"colEnd":\#(column + 1),"rowStart":\#(row),"rowEnd":\#(row + 1)}"#
                )
            }
        }
        let zones = "[" + cells.joined(separator: ",") + "]"
        let manyZones = try inspect(file([layoutJSON(columns: columns, rows: rows, zones: zones)]))
        #expect(manyZones.layouts.isEmpty && manyZones.rejected == 1)
        let tracks = "[" + Array(repeating: "1", count: 33).joined(separator: ",") + "]"
        let wide = #"[{"id":1,"colStart":0,"colEnd":33,"rowStart":0,"rowEnd":1}]"#
        let manyTracks = try inspect(file([layoutJSON(columns: tracks, rows: "[1]", zones: wide)]))
        #expect(manyTracks.layouts.isEmpty && manyTracks.rejected == 1)
        // At the limits it still works: 32 tracks, 64 zones.
        let edge = try inspect(
            file([
                layoutJSON(
                    columns: "[" + Array(repeating: "1", count: 32).joined(separator: ",") + "]", rows: "[1]",
                    zones: "["
                        + (0..<32).map {
                            #"{"id":\#($0 + 1),"colStart":\#($0),"colEnd":\#($0 + 1),"rowStart":0,"rowEnd":1}"#
                        }.joined(separator: ",") + "]")
            ]))
        #expect(edge.layouts.count == 1)
    }

    @Test func namesAreLimitedAndFreeOfControlAndBidiCharacters() throws {
        let hostile = [
            String(repeating: "a", count: 65), #"bell\u0007"#, #"nul\u0000"#, #"line\nbreak"#, #"flip‮evil"#,
            #"iso⁦x"#, #"mark‏x"#, "   ",
        ]
        for name in hostile {
            let preview = try inspect(file([layoutJSON(name: name)]))
            #expect(preview.layouts.isEmpty, "\(name)")
            #expect(preview.rejected == 1)
        }
        let fine = try inspect(file([layoutJSON(name: String(repeating: "ł", count: 64))]))
        #expect(fine.layouts.count == 1)
    }

    @Test func aNewerVersionAndGarbageAreRefused() {
        #expect(throws: ImportError.newerVersion) { try inspect(file([layoutJSON()], version: 2)) }
        #expect(throws: ImportError.malformed) { try inspect(Data("garbage".utf8)) }
        #expect(throws: ImportError.malformed) { try inspect(Data(#"{"version":0,"layouts":[]}"#.utf8)) }
        #expect(throws: ImportError.malformed) { try inspect(Data(#"{"layouts":[]}"#.utf8)) }
        #expect(throws: ImportError.malformed) { try inspect(Data(#"[1,2,3]"#.utf8)) }
    }

    // MARK: Export

    @Test func exportRoundTripsThroughTheSameValidatorWithoutSlotsOrAssignments() throws {
        var mine = StockLayouts.layout(StockLayouts.priority)!
        mine.id = "user.p"
        mine.name = "Mine"
        let data = try LayoutExporter.data(for: [mine, StockLayouts.layout(StockLayouts.grid2x2)!])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("slots") && !text.contains("assignments") && !text.contains("hotkeyID"))
        let preview = try inspect(data)
        #expect(preview.layouts.count == 2)
        #expect(preview.layouts[0] == mine)
        // A stock template is exported under a new id, so it never collides with the app's own.
        #expect(!StockLayouts.isStock(preview.layouts[1].id))
        #expect(preview.layouts[1].zones == StockLayouts.layout(StockLayouts.grid2x2)?.zones)
        #expect(preview.regeneratedIDs == 0)
    }

    @Test func importAddsToTheLibraryInOneWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "lintel-imp2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LayoutRepository(directory: directory)
        let existing = try await repository.create(StockLayouts.layout(StockLayouts.columns3)!)
        let preview = try inspect(
            file([layoutJSON(id: existing.id, name: "Twin"), layoutJSON(id: "user.new", name: "New")]),
            existing: Set(await repository.userLayouts.map(\.id)))
        let added = try await repository.add(preview.layouts)
        #expect(added.count == 2)
        #expect(await repository.userLayouts.count == 3)
        #expect(Set(await repository.userLayouts.map(\.id)).count == 3)
    }
}
