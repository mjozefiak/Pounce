import CoreGraphics
import Foundation
import LintelKit

/// The layouts a build knows. Phase 3 has only the stock templates; the user's library (phase 4) joins them
/// here, so resolution and placement do not change.
struct LayoutLibrary: Equatable, Sendable {
    private(set) var layouts: [String: GridLayout]

    init(_ layouts: [GridLayout] = StockLayouts.all) {
        self.layouts = Dictionary(layouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static let stock = LayoutLibrary()

    func layout(_ id: String) -> GridLayout? { layouts[id] }
    func contains(_ id: String) -> Bool { layouts[id] != nil }
}

/// The display a zone assignment is keyed by (spec: Data Model): a display's UUID, or the shape of a display for
/// every display of that shape that has no assignment of its own. Local only, never logged.
enum DisplayKeys {
    static let landscape = "landscape"
    static let portrait = "portrait"

    static func orientationKey(_ orientation: DisplayOrientation) -> String {
        orientation == .portrait ? portrait : landscape
    }

    /// The key of every display. Two identical monitors without serial numbers can share a UUID; they are then
    /// told apart by their position (left to right, then top to bottom): the first keeps the UUID, the next ones
    /// get `uuid#2`, `uuid#3`. `hasDuplicates` is what the pane says out loud.
    static func keys(for displays: [DisplayInfo]) -> (keys: [UInt32: String], hasDuplicates: Bool) {
        var result: [UInt32: String] = [:]
        var duplicates = false
        let byUUID = Dictionary(grouping: displays, by: \.uuid)
        for (uuid, group) in byUUID {
            let ordered = group.sorted {
                ($0.frame.minX, $0.frame.minY, $0.id) < ($1.frame.minX, $1.frame.minY, $1.id)
            }
            if ordered.count > 1 { duplicates = true }
            for (index, display) in ordered.enumerated() {
                result[display.id] = index == 0 ? uuid : "\(uuid)#\(index + 1)"
            }
        }
        return (result, duplicates)
    }
}

/// One assignment: the layout a workspace uses on a display (or on every display of a shape).
struct ZoneAssignment: Equatable, Hashable, Sendable {
    var workspace: WorkspaceID
    var displayKey: String
    var layoutID: String
}

/// The content of `assignments.json` as values: at most one layout per workspace and display key.
struct AssignmentTable: Equatable, Sendable {
    private(set) var entries: [ZoneAssignment] = []

    init(_ assignments: [ZoneAssignment] = []) {
        for assignment in assignments {
            set(assignment.layoutID, workspace: assignment.workspace, displayKey: assignment.displayKey)
        }
    }

    func layoutID(workspace: WorkspaceID, displayKey: String) -> String? {
        entries.first { $0.workspace == workspace && $0.displayKey == displayKey }?.layoutID
    }

    /// Sets the layout of one cell, or clears it with `nil` (the cell then uses the default).
    mutating func set(_ layoutID: String?, workspace: WorkspaceID, displayKey: String) {
        entries.removeAll { $0.workspace == workspace && $0.displayKey == displayKey }
        if let layoutID {
            entries.append(ZoneAssignment(workspace: workspace, displayKey: displayKey, layoutID: layoutID))
        }
    }

    /// How many cells use a layout (what deleting it would change).
    func count(using layoutID: String) -> Int { entries.filter { $0.layoutID == layoutID }.count }

    var isEmpty: Bool { entries.isEmpty }
}

/// Where the layout a workspace got on a display came from.
enum ZoneLayoutSource: Equatable, Sendable {
    /// An assignment for this display.
    case assigned
    /// An assignment for every display of this shape.
    case assignedForShape
    /// The default of the display's shape (settings).
    case defaultOfShape
    /// The built-in default, because the settings named a layout that does not exist.
    case builtIn
}

struct ResolvedZoneLayout: Equatable, Sendable {
    var layout: GridLayout
    var source: ZoneLayoutSource
    /// An assignment (or the default) named a layout that is not in the library, so the next choice was used. The
    /// pane reports it.
    var fellBack: Bool
}

/// What the engine needs to choose a zone layout: the assignments, the library and the two defaults (spec Q19).
struct ZonesConfig: Equatable, Sendable {
    var assignments = AssignmentTable()
    var library = LayoutLibrary.stock
    var defaultLandscape = StockLayouts.defaultLandscape
    var defaultPortrait = StockLayouts.defaultPortrait

    func defaultID(for orientation: DisplayOrientation) -> String {
        orientation == .portrait ? defaultPortrait : defaultLandscape
    }

    /// The layout of a workspace on a display: its own assignment, then the one for the display's shape, then
    /// the default of that shape, then the built-in default. A missing layout (deleted, or from a file of a
    /// newer version) skips to the next choice and sets `fellBack`. Zones needing a display always get a valid
    /// layout: the built-in defaults are compiled in.
    func resolve(workspace: WorkspaceID, displayKey: String, orientation: DisplayOrientation) -> ResolvedZoneLayout {
        var fellBack = false
        let candidates: [(String?, ZoneLayoutSource)] = [
            (assignments.layoutID(workspace: workspace, displayKey: displayKey), .assigned),
            (
                assignments.layoutID(workspace: workspace, displayKey: DisplayKeys.orientationKey(orientation)),
                .assignedForShape
            ),
            (defaultID(for: orientation), .defaultOfShape),
        ]
        for (id, source) in candidates {
            guard let id else { continue }
            if let layout = library.layout(id), layout.isValid {
                return ResolvedZoneLayout(layout: layout, source: source, fellBack: fellBack)
            }
            fellBack = true
        }
        let builtIn = orientation == .portrait ? StockLayouts.defaultPortrait : StockLayouts.defaultLandscape
        let layout = StockLayouts.layout(builtIn) ?? StockLayouts.all[0]
        return ResolvedZoneLayout(layout: layout, source: .builtIn, fellBack: fellBack)
    }
}
