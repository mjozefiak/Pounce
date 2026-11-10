import CoreGraphics
import Foundation

/// One zone of a grid layout: a rectangle of cells. The end indices are exclusive, so a zone that covers the
/// first column of the first row is `colStart 0, colEnd 1, rowStart 0, rowEnd 1`.
struct GridZone: Equatable, Hashable, Codable, Sendable {
    var id: Int
    var colStart: Int
    var colEnd: Int
    var rowStart: Int
    var rowEnd: Int
}

/// Why a grid layout is not valid (spec: Data Model, "Validation on load and before save").
enum GridLayoutError: Error, Equatable, Sendable {
    case noTracks
    case tooManyTracks
    case badWeight
    case noZones
    case tooManyZones
    case badSpacing
    case duplicateZoneID
    case zoneOutsideGrid
    /// A cell that no zone covers.
    case cellUncovered
    /// A cell that more than one zone covers.
    case cellCoveredTwice
}

/// A zone layout in the grid style (spec: Proposed Solution, "Zone layouts"): column and row track weights plus
/// zones that are rectangles of cells, so the zones always tile the display. Resolution independent: frames are
/// computed from the usable area of a display. The zone's *number* (the one on the overlay and in the
/// `zones.zone.N` commands) is its position in `zones` plus one.
struct GridLayout: Equatable, Sendable {
    /// The most tracks and zones a layout may have (the import limits of the spec).
    static let maximumTracks = 32
    static let maximumZones = 64
    static let maximumSpacing = 64
    /// The largest weight of one track; with at most 32 tracks the sum stays finite and the frames never turn
    /// into NaN.
    static let maximumWeight = 1_000_000.0

    var id: String
    /// What the library shows. Stock layouts carry their English name here; the UI looks stock names up in the
    /// string catalog (`StockLayouts.name(of:)`), a user's layout name is shown as it is.
    var name: String
    var spacing: Int
    var columns: [Double]
    var rows: [Double]
    var zones: [GridZone]

    init(id: String, name: String, spacing: Int = 8, columns: [Double], rows: [Double], zones: [GridZone]) {
        self.id = id
        self.name = name
        self.spacing = spacing
        self.columns = columns
        self.rows = rows
        self.zones = zones
    }

    /// Checks every rule: tracks (1 to 32, finite positive weights), zones (1 to 64, unique ids, inside the grid)
    /// and that the zones cover every cell exactly once.
    func validate() throws(GridLayoutError) {
        guard !columns.isEmpty, !rows.isEmpty else { throw .noTracks }
        guard columns.count <= Self.maximumTracks, rows.count <= Self.maximumTracks else { throw .tooManyTracks }
        guard (columns + rows).allSatisfy({ $0.isFinite && $0 > 0 && $0 <= Self.maximumWeight }) else {
            throw .badWeight
        }
        guard columns.reduce(0, +).isFinite, rows.reduce(0, +).isFinite else { throw .badWeight }
        guard (0...Self.maximumSpacing).contains(spacing) else { throw .badSpacing }
        guard !zones.isEmpty else { throw .noZones }
        guard zones.count <= Self.maximumZones else { throw .tooManyZones }
        guard Set(zones.map(\.id)).count == zones.count else { throw .duplicateZoneID }
        var covered = Array(repeating: Array(repeating: 0, count: columns.count), count: rows.count)
        for zone in zones {
            guard zone.colStart >= 0, zone.colStart < zone.colEnd, zone.colEnd <= columns.count,
                zone.rowStart >= 0, zone.rowStart < zone.rowEnd, zone.rowEnd <= rows.count
            else { throw .zoneOutsideGrid }
            for row in zone.rowStart..<zone.rowEnd {
                for column in zone.colStart..<zone.colEnd { covered[row][column] += 1 }
            }
        }
        for row in covered {
            if row.contains(0) { throw .cellUncovered }
            if row.contains(where: { $0 > 1 }) { throw .cellCoveredTwice }
        }
    }

    var isValid: Bool {
        do {
            try validate()
            return true
        } catch {
            return false
        }
    }

    /// The zone with that number (1 to `zones.count`).
    func zone(number: Int) -> GridZone? {
        guard number >= 1, number <= zones.count else { return nil }
        return zones[number - 1]
    }

    func number(ofZone id: Int) -> Int? {
        zones.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    // MARK: Frames

    /// The frame of every zone, by zone id, inside `area`: `spacing` points around the zones and between them
    /// (shrunk, like Auto-tile's gaps, when there are so many tracks that they would take more than a quarter of
    /// the length). Edges are whole points; a zone's edge is exactly where its neighbour's starts plus the gap, and
    /// the outer edges reach the spacing exactly. An invalid layout has no frames.
    func frames(in area: CGRect) -> [Int: CGRect] {
        guard isValid else { return [:] }
        let outer = CGFloat(spacing)
        let dx = min(outer, area.width / 2)
        let dy = min(outer, area.height / 2)
        let inner = area.insetBy(dx: dx, dy: dy)
        let xs = Self.tracks(columns, origin: inner.minX, length: inner.width, gap: outer)
        let ys = Self.tracks(rows, origin: inner.minY, length: inner.height, gap: outer)
        var result: [Int: CGRect] = [:]
        for zone in zones {
            let left = xs[zone.colStart].lowerBound
            let right = xs[zone.colEnd - 1].upperBound
            let top = ys[zone.rowStart].lowerBound
            let bottom = ys[zone.rowEnd - 1].upperBound
            result[zone.id] = CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
        }
        return result
    }

    /// The start and end of each track along one axis.
    private static func tracks(
        _ weights: [Double], origin: CGFloat, length: CGFloat, gap: CGFloat
    ) -> [Range<CGFloat>] {
        let count = weights.count
        let gap = count > 1 ? min(gap, length / CGFloat(4 * (count - 1))) : 0
        let available = max(0, length - gap * CGFloat(count - 1))
        let total = weights.reduce(0, +)
        var consumed: Double = 0
        var result: [Range<CGFloat>] = []
        for (index, weight) in weights.enumerated() {
            let lower = origin + CGFloat(consumed / total) * available + CGFloat(index) * gap
            consumed += weight
            let upper = origin + CGFloat(consumed / total) * available + CGFloat(index) * gap
            let low = lower.rounded()
            let high = index == count - 1 ? (origin + length).rounded() : upper.rounded()
            result.append(low..<max(low, high))
        }
        return result
    }

    /// The zone whose frame holds the point (a hit test).
    func zoneID(at point: CGPoint, in area: CGRect) -> Int? {
        let all = frames(in: area)
        // Gaps belong to no zone, but a cursor in a gap should still pick something: the nearest frame.
        if let hit = zones.first(where: { all[$0.id]?.contains(point) == true }) { return hit.id }
        var best: (id: Int, distance: CGFloat)?
        for zone in zones {
            guard let frame = all[zone.id] else { continue }
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = dx * dx + dy * dy
            if best == nil || distance < best?.distance ?? .infinity { best = (zone.id, distance) }
        }
        guard let best, area.insetBy(dx: -1, dy: -1).contains(point) else { return nil }
        return best.id
    }

    // MARK: Neighbours

    /// The zone next to `id` in a direction, by grid position: the nearest zone beyond its edge that shares at
    /// least one row (or column) with it, the one with the largest overlap first, then the first in zone order.
    func neighbour(of id: Int, _ direction: TilingDirection) -> Int? {
        guard let from = zones.first(where: { $0.id == id }) else { return nil }
        var best: (zone: GridZone, gap: Int, overlap: Int)?
        for zone in zones where zone.id != id {
            let rowOverlap = max(0, min(zone.rowEnd, from.rowEnd) - max(zone.rowStart, from.rowStart))
            let columnOverlap = max(0, min(zone.colEnd, from.colEnd) - max(zone.colStart, from.colStart))
            let gap: Int
            let overlap: Int
            switch direction {
            case .left:
                gap = from.colStart - zone.colEnd
                overlap = rowOverlap
            case .right:
                gap = zone.colStart - from.colEnd
                overlap = rowOverlap
            case .up:
                gap = from.rowStart - zone.rowEnd
                overlap = columnOverlap
            case .down:
                gap = zone.rowStart - from.rowEnd
                overlap = columnOverlap
            }
            guard gap >= 0, overlap > 0 else { continue }
            if let current = best, (gap, -overlap) >= (current.gap, -current.overlap) { continue }
            best = (zone, gap, overlap)
        }
        return best?.zone.id
    }
}

/// The templates compiled into the app (spec: Q18: read-only; "Duplicate" makes an editable copy).
/// Their ids never change: `assignments.json` refers to them.
enum StockLayouts {
    static let focus = "stock.focus"
    static let columns2 = "stock.columns2"
    static let columns3 = "stock.columns3"
    static let rows2 = "stock.rows2"
    static let grid2x2 = "stock.grid2x2"
    static let priority = "stock.priority"

    static let idPrefix = "stock."

    static func isStock(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// Default layout of a landscape display and of a portrait one (spec Q19).
    static let defaultLandscape = columns2
    static let defaultPortrait = rows2

    private static func cell(_ id: Int, _ column: Int, _ row: Int) -> GridZone {
        GridZone(id: id, colStart: column, colEnd: column + 1, rowStart: row, rowEnd: row + 1)
    }

    static let all: [GridLayout] = [
        GridLayout(id: focus, name: "Focus", columns: [1], rows: [1], zones: [cell(1, 0, 0)]),
        GridLayout(
            id: columns2, name: "Columns 2", columns: [1, 1], rows: [1], zones: [cell(1, 0, 0), cell(2, 1, 0)]),
        GridLayout(
            id: columns3, name: "Columns 3", columns: [1, 1, 1], rows: [1],
            zones: [cell(1, 0, 0), cell(2, 1, 0), cell(3, 2, 0)]),
        GridLayout(id: rows2, name: "Rows 2", columns: [1], rows: [1, 1], zones: [cell(1, 0, 0), cell(2, 0, 1)]),
        GridLayout(
            id: grid2x2, name: "Grid 2×2", columns: [1, 1], rows: [1, 1],
            zones: [cell(1, 0, 0), cell(2, 1, 0), cell(3, 0, 1), cell(4, 1, 1)]),
        GridLayout(
            id: priority, name: "Priority 25/50/25", columns: [1, 2, 1], rows: [1],
            zones: [cell(1, 0, 0), cell(2, 1, 0), cell(3, 2, 0)]),
    ]

    static func layout(_ id: String) -> GridLayout? { all.first { $0.id == id } }

    /// The name to show: stock names come from the string catalog, anything else is user data and shown as it is.
    static func displayName(of layout: GridLayout) -> String {
        switch layout.id {
        case focus: String(localized: "Focus", comment: "Zone layout template: one zone")
        case columns2: String(localized: "Columns 2", comment: "Zone layout template: two columns")
        case columns3: String(localized: "Columns 3", comment: "Zone layout template: three columns")
        case rows2: String(localized: "Rows 2", comment: "Zone layout template: two rows")
        case grid2x2: String(localized: "Grid 2×2", comment: "Zone layout template: four zones in a grid")
        case priority:
            String(localized: "Priority 25/50/25", comment: "Zone layout template: a wide middle zone between two")
        default: layout.name
        }
    }
}

/// The JSON shape of a layout in `layouts.json` and in `.lintellayouts` files (spec: Data Model): the style is
/// kept with the reserved value `canvas`, so a later spec can add free zones without a migration. A layout of a
/// style this build does not know is kept as it is and never offered for assignment.
struct LayoutRecord: Codable, Equatable, Sendable {
    struct Grid: Codable, Equatable, Sendable {
        var columns: [Double]
        var rows: [Double]
        var zones: [GridZone]
    }

    static let gridStyle = "grid"
    static let canvasStyle = "canvas"

    var id: String
    var name: String
    var style: String
    var spacing: Int
    var hotkeyID: String?
    var grid: Grid?

    init(_ layout: GridLayout) {
        id = layout.id
        name = layout.name
        style = Self.gridStyle
        spacing = layout.spacing
        hotkeyID = nil
        grid = Grid(columns: layout.columns, rows: layout.rows, zones: layout.zones)
    }

    /// The grid layout this record describes, or `nil` for another style (kept untouched by the caller). Throws
    /// when a grid record breaks a rule.
    func gridLayout() throws(GridLayoutError) -> GridLayout? {
        guard style == Self.gridStyle, let grid else { return nil }
        let layout = GridLayout(
            id: id, name: name, spacing: spacing, columns: grid.columns, rows: grid.rows, zones: grid.zones)
        try layout.validate()
        return layout
    }
}
