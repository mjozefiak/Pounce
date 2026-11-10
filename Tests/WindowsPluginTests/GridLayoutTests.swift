import CoreGraphics
import Foundation
import Testing

@testable import WindowsPlugin

/// The grid layout maths and the stock templates (step 3.1): golden frames, validation, neighbours, the record.
@Suite(.timeLimit(.minutes(1))) struct GridLayoutTests {
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)

    private func frames(_ id: String, spacing: Int? = nil) throws -> [Int: CGRect] {
        var layout = try #require(StockLayouts.layout(id))
        if let spacing { layout.spacing = spacing }
        return layout.frames(in: area)
    }

    // MARK: Golden frames (spacing 8 around and between)

    @Test func focusFillsTheAreaMinusTheSpacing() throws {
        #expect(try frames(StockLayouts.focus) == [1: CGRect(x: 8, y: 8, width: 984, height: 584)])
    }

    @Test func columnsTwo() throws {
        #expect(
            try frames(StockLayouts.columns2) == [
                1: CGRect(x: 8, y: 8, width: 488, height: 584),
                2: CGRect(x: 504, y: 8, width: 488, height: 584),
            ])
    }

    @Test func columnsThreeRoundsToWholePointsAndReachesTheEdge() throws {
        let result = try frames(StockLayouts.columns3)
        #expect(result[1] == CGRect(x: 8, y: 8, width: 323, height: 584))
        #expect(result[2] == CGRect(x: 339, y: 8, width: 322, height: 584))
        #expect(result[3] == CGRect(x: 669, y: 8, width: 323, height: 584))
    }

    @Test func rowsTwo() throws {
        #expect(
            try frames(StockLayouts.rows2) == [
                1: CGRect(x: 8, y: 8, width: 984, height: 288),
                2: CGRect(x: 8, y: 304, width: 984, height: 288),
            ])
    }

    @Test func gridTwoByTwo() throws {
        #expect(
            try frames(StockLayouts.grid2x2) == [
                1: CGRect(x: 8, y: 8, width: 488, height: 288),
                2: CGRect(x: 504, y: 8, width: 488, height: 288),
                3: CGRect(x: 8, y: 304, width: 488, height: 288),
                4: CGRect(x: 504, y: 304, width: 488, height: 288),
            ])
    }

    @Test func priorityGivesTheMiddleHalf() throws {
        #expect(
            try frames(StockLayouts.priority) == [
                1: CGRect(x: 8, y: 8, width: 242, height: 584),
                2: CGRect(x: 258, y: 8, width: 484, height: 584),
                3: CGRect(x: 750, y: 8, width: 242, height: 584),
            ])
    }

    @Test func noSpacingTouchesTheEdges() throws {
        #expect(
            try frames(StockLayouts.columns2, spacing: 0) == [
                1: CGRect(x: 0, y: 0, width: 500, height: 600),
                2: CGRect(x: 500, y: 0, width: 500, height: 600),
            ])
    }

    @Test func anOffsetAreaMovesEveryFrame() throws {
        let layout = try #require(StockLayouts.layout(StockLayouts.columns2))
        let shifted = layout.frames(in: CGRect(x: 100, y: 50, width: 1000, height: 600))
        #expect(shifted[1] == CGRect(x: 108, y: 58, width: 488, height: 584))
    }

    @Test func aMergedZoneSpansTheGapBetweenItsCells() {
        let layout = GridLayout(
            id: "x", name: "x", columns: [1, 1], rows: [1, 1],
            zones: [
                GridZone(id: 1, colStart: 0, colEnd: 1, rowStart: 0, rowEnd: 2),
                GridZone(id: 2, colStart: 1, colEnd: 2, rowStart: 0, rowEnd: 1),
                GridZone(id: 3, colStart: 1, colEnd: 2, rowStart: 1, rowEnd: 2),
            ])
        let result = layout.frames(in: area)
        #expect(result[1] == CGRect(x: 8, y: 8, width: 488, height: 584))
        #expect(result[3] == CGRect(x: 504, y: 304, width: 488, height: 288))
    }

    @Test func framesNeverOverlapAndStayInsideTheArea() {
        for layout in StockLayouts.all {
            let result = Array(layout.frames(in: area).values)
            for (index, first) in result.enumerated() {
                #expect(area.contains(first))
                for second in result.dropFirst(index + 1) {
                    let overlap = first.intersection(second)
                    #expect(overlap.isNull || overlap.isEmpty)
                }
            }
        }
    }

    @Test func aTinyAreaNeverGivesNegativeSizes() {
        let layout = StockLayouts.layout(StockLayouts.grid2x2)
        let result = layout?.frames(in: CGRect(x: 0, y: 0, width: 10, height: 10)) ?? [:]
        #expect(result.count == 4)
        for frame in result.values { #expect(frame.width >= 0 && frame.height >= 0) }
    }

    @Test func anInvalidLayoutHasNoFrames() {
        let layout = GridLayout(id: "x", name: "x", columns: [1, 1], rows: [1], zones: [])
        #expect(layout.frames(in: area).isEmpty)
    }

    // MARK: Stock templates

    @Test func everyStockTemplateIsValidAndHasAStableId() throws {
        #expect(
            StockLayouts.all.map(\.id) == [
                "stock.focus", "stock.columns2", "stock.columns3", "stock.rows2", "stock.grid2x2", "stock.priority",
            ])
        for layout in StockLayouts.all {
            try layout.validate()
            #expect(StockLayouts.isStock(layout.id))
        }
        #expect(StockLayouts.all.map { $0.zones.count } == [1, 2, 3, 2, 4, 3])
        #expect(StockLayouts.defaultLandscape == StockLayouts.columns2)
        #expect(StockLayouts.defaultPortrait == StockLayouts.rows2)
    }

    @Test func aStockNameComesFromTheCatalogAndAUserNameIsShownAsIs() {
        let stock = StockLayouts.layout(StockLayouts.columns2)
        #expect(stock.map(StockLayouts.displayName(of:)) == "Columns 2")
        let mine = GridLayout(id: "u1", name: "Columns 2", columns: [1], rows: [1], zones: StockLayouts.all[0].zones)
        #expect(StockLayouts.displayName(of: mine) == "Columns 2")
    }

    // MARK: Validation

    private func cell(_ id: Int, _ column: Int, _ row: Int) -> GridZone {
        GridZone(id: id, colStart: column, colEnd: column + 1, rowStart: row, rowEnd: row + 1)
    }

    private func checks(_ layout: GridLayout) -> GridLayoutError? {
        do {
            try layout.validate()
            return nil
        } catch { return error }
    }

    @Test func validationRejectsEveryBrokenRule() {
        let base = GridLayout(id: "x", name: "x", columns: [1, 1], rows: [1], zones: [cell(1, 0, 0), cell(2, 1, 0)])
        #expect(checks(base) == nil)
        var layout = base
        layout.columns = []
        #expect(checks(layout) == .noTracks)
        layout = base
        layout.columns = Array(repeating: 1, count: 33)
        #expect(checks(layout) == .tooManyTracks)
        for weight in [0, -1, Double.nan, Double.infinity, 1e308, 1_000_001] {
            layout = base
            layout.columns = [1, weight]
            #expect(checks(layout) == .badWeight)
        }
        layout = base
        layout.spacing = 65
        #expect(checks(layout) == .badSpacing)
        layout.spacing = -1
        #expect(checks(layout) == .badSpacing)
        layout = base
        layout.zones = []
        #expect(checks(layout) == .noZones)
        layout = base
        layout.zones = [cell(1, 0, 0), cell(1, 1, 0)]
        #expect(checks(layout) == .duplicateZoneID)
        layout = base
        layout.zones = [cell(1, 0, 0), cell(2, 2, 0)]
        #expect(checks(layout) == .zoneOutsideGrid)
        layout.zones = [cell(1, 0, 0), GridZone(id: 2, colStart: 1, colEnd: 1, rowStart: 0, rowEnd: 1)]
        #expect(checks(layout) == .zoneOutsideGrid)
    }

    @Test func hugeWeightsNeverGiveNaNFrames() {
        let big = GridLayout.maximumWeight
        let layout = GridLayout(
            id: "x", name: "x", columns: [big, big], rows: [1], zones: [cell(1, 0, 0), cell(2, 1, 0)])
        #expect(checks(layout) == nil)
        let frames = layout.frames(in: area)
        #expect(frames.count == 2)
        for frame in frames.values { #expect(frame.origin.x.isFinite && frame.width.isFinite && frame.width > 0) }
        let broken = GridLayout(
            id: "x", name: "x", columns: [1e308, 1e308], rows: [1], zones: [cell(1, 0, 0), cell(2, 1, 0)])
        #expect(broken.frames(in: area).isEmpty)
    }

    @Test func zonesMustCoverEveryCellExactlyOnce() {
        let base = GridLayout(id: "x", name: "x", columns: [1, 1], rows: [1], zones: [cell(1, 0, 0)])
        #expect(checks(base) == .cellUncovered)
        var layout = base
        layout.zones = [cell(1, 0, 0), cell(2, 1, 0), cell(3, 1, 0)]
        #expect(checks(layout) == .cellCoveredTwice)
        layout.zones = [GridZone(id: 1, colStart: 0, colEnd: 2, rowStart: 0, rowEnd: 1), cell(2, 1, 0)]
        #expect(checks(layout) == .cellCoveredTwice)
    }

    @Test func tooManyZonesAreRefused() {
        let columns = Array(repeating: 1.0, count: 32)
        let zones = (0..<65).map { cell($0, $0 % 32, 0) }
        let layout = GridLayout(id: "x", name: "x", columns: columns, rows: [1, 1], zones: zones)
        #expect(checks(layout) == .tooManyZones)
    }

    // MARK: Hit test and neighbours

    @Test func aPointPicksTheZoneUnderItAndTheNearestInAGap() throws {
        let layout = try #require(StockLayouts.layout(StockLayouts.columns2))
        #expect(layout.zoneID(at: CGPoint(x: 100, y: 100), in: area) == 1)
        #expect(layout.zoneID(at: CGPoint(x: 900, y: 100), in: area) == 2)
        #expect(layout.zoneID(at: CGPoint(x: 500, y: 100), in: area) != nil)
        #expect(layout.zoneID(at: CGPoint(x: 2000, y: 100), in: area) == nil)
    }

    @Test func neighboursFollowTheGrid() throws {
        let grid = try #require(StockLayouts.layout(StockLayouts.grid2x2))
        #expect(grid.neighbour(of: 1, .right) == 2)
        #expect(grid.neighbour(of: 1, .down) == 3)
        #expect(grid.neighbour(of: 4, .left) == 3)
        #expect(grid.neighbour(of: 4, .up) == 2)
        #expect(grid.neighbour(of: 1, .left) == nil)
        #expect(grid.neighbour(of: 1, .up) == nil)
        let columns = try #require(StockLayouts.layout(StockLayouts.columns3))
        #expect(columns.neighbour(of: 1, .right) == 2)
        #expect(columns.neighbour(of: 3, .left) == 2)
        #expect(columns.neighbour(of: 2, .down) == nil)
    }

    @Test func aTallZoneNextToTwoPicksTheLargestOverlapThenTheFirst() {
        let layout = GridLayout(
            id: "x", name: "x", columns: [1, 1], rows: [1, 1],
            zones: [
                GridZone(id: 1, colStart: 0, colEnd: 1, rowStart: 0, rowEnd: 2),
                cell(2, 1, 0), cell(3, 1, 1),
            ])
        #expect(layout.neighbour(of: 1, .right) == 2)
        #expect(layout.neighbour(of: 3, .left) == 1)
    }

    @Test func zoneNumbersArePositionsInTheList() throws {
        let layout = try #require(StockLayouts.layout(StockLayouts.grid2x2))
        #expect(layout.zone(number: 3)?.id == 3)
        #expect(layout.zone(number: 0) == nil)
        #expect(layout.zone(number: 5) == nil)
        #expect(layout.number(ofZone: 4) == 4)
    }

    // MARK: The file format

    @Test func theRecordRoundTripsAndKeepsTheStyleField() throws {
        let layout = try #require(StockLayouts.layout(StockLayouts.priority))
        let record = LayoutRecord(layout)
        #expect(record.style == "grid")
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(LayoutRecord.self, from: data)
        #expect(try decoded.gridLayout() == layout)
    }

    @Test func aCanvasRecordIsKeptButHasNoGridLayout() throws {
        let json = #"{"id":"c1","name":"Free","style":"canvas","spacing":0}"#
        let record = try JSONDecoder().decode(LayoutRecord.self, from: Data(json.utf8))
        #expect(record.style == LayoutRecord.canvasStyle)
        #expect(try record.gridLayout() == nil)
    }

    @Test func aGridRecordThatBreaksARuleThrows() throws {
        var record = LayoutRecord(try #require(StockLayouts.layout(StockLayouts.columns2)))
        record.grid?.zones = [GridZone(id: 1, colStart: 0, colEnd: 1, rowStart: 0, rowEnd: 1)]
        #expect(throws: GridLayoutError.cellUncovered) { try record.gridLayout() }
    }
}
