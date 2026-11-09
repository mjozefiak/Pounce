import CoreGraphics
import Foundation
import LintelKit
import Observation

/// One display as a column of the assignment matrix.
struct MatrixDisplay: Identifiable, Equatable {
    /// The display key (`DisplayKeys`): the display's UUID. Never logged, never shown.
    var key: String
    /// 1 for the first display in the list, as *Identify* shows it.
    var number: Int
    var title: String
    var detail: String
    var orientation: DisplayOrientation
    var area: CGRect

    var id: String { key }
}

/// A cell of the matrix: the layout a workspace uses on a display and how to say so.
struct MatrixCell: Equatable {
    var workspace: WorkspaceID
    var displayKey: String
    /// The layout chosen for this cell, `nil` when it follows the default.
    var assignedID: String?
    var effective: ResolvedZoneLayout
    /// "Columns 2 · default": the layout that applies and why.
    var label: String
    /// The workspace is Auto-tile or Free, so no zone layout is in use there.
    var isInactive: Bool
}

struct MatrixPosition: Equatable {
    var row: Int
    var column: Int
}

/// What a key does to the matrix (step 3.6, the keyboard table): arrows move between cells, ⌫ gives the cell back
/// to the default and 1 to 6 choose a stock layout for it.
enum MatrixKey: Equatable {
    case left, right, up, down
    case clear
    case layout(Int)
}

/// Where *Apply to…* writes a layout.
enum ApplyTarget: Equatable {
    case everything
    case display(String)
    case workspace(WorkspaceID)
}

/// The Layouts window's state (spec: UI/UX, mockup 05): the assignment matrix of workspaces by displays over the
/// stock layouts, the layout kind of each workspace, *Identify* and *Apply to…*. It reads and writes through the
/// running plugin (the assignment file and the overrides), so a plugin that is off has nothing to edit.
@MainActor @Observable
final class LayoutsModel {
    /// What the views' buttons start, in the order the user pressed them.
    let actions = OrderedActions()
    @ObservationIgnored let pane: WindowsSettingsModel
    @ObservationIgnored private let loadDisplays: () async -> [DisplayInfo]
    @ObservationIgnored private let identifier: (MatrixDisplay) -> Void
    @ObservationIgnored let openEditor: (GridLayout, Bool, @escaping (GridLayout) -> Void) -> Void
    @ObservationIgnored let files: any LayoutFileAccess

    private(set) var displays: [MatrixDisplay] = []
    var table = AssignmentTable()
    private(set) var hasDuplicateDisplays = false
    private(set) var isLocked = false
    /// The last write failed: the window says so instead of only logging it.
    private(set) var writeFailed = false
    /// The layout shown in the detail card.
    var selectedLayoutID = StockLayouts.columns2
    var focused: MatrixPosition?

    // The library (`LayoutsModel+Library.swift`).
    var userLayouts: [GridLayout] = []
    var slots: [Int: String] = [:]
    /// `layouts.json` comes from a newer version: the library can be read, never changed.
    var libraryLocked = false
    /// Layouts kept untouched because this build cannot use them (another style, or broken).
    var keptUntouched = 0
    /// What the last library action did, or why it did not (shown under the list).
    var notice: String?
    var pendingImport: ImportPreview?
    var pendingDelete: LayoutDeletion?
    var isRenaming = false

    init(
        pane: WindowsSettingsModel, displays: @escaping () async -> [DisplayInfo],
        identify: @escaping (MatrixDisplay) -> Void = { _ in },
        openEditor: @escaping (GridLayout, Bool, @escaping (GridLayout) -> Void) -> Void = { _, _, _ in },
        files: any LayoutFileAccess = NoLayoutFiles()
    ) {
        self.pane = pane
        loadDisplays = displays
        identifier = identify
        self.openEditor = openEditor
        self.files = files
    }

    // MARK: State

    var library: LayoutLibrary { LayoutLibrary(StockLayouts.all + userLayouts) }
    var stockLayouts: [GridLayout] { StockLayouts.all }
    var selectedLayout: GridLayout { library.layout(selectedLayoutID) ?? StockLayouts.all[0] }

    /// Whether the plugin is running: the matrix can be edited and *Identify* works.
    var isActive: Bool { pane.runtime() != nil }

    /// Assignments can be changed: the plugin runs and the file is not from a newer version.
    var canEdit: Bool { isActive && !isLocked }

    var workspaces: [WorkspaceID] { WorkspaceID.all(count: pane.settings.workspaceCount) }

    func refresh() async {
        let infos = await loadDisplays()
        let keyed = DisplayKeys.keys(for: infos)
        hasDuplicateDisplays = keyed.hasDuplicates
        let ordered = infos.sorted {
            if $0.isMain != $1.isMain { return $0.isMain }
            return ($0.frame.minX, $0.frame.minY, $0.id) < ($1.frame.minX, $1.frame.minY, $1.id)
        }
        displays = ordered.enumerated().map { index, info in
            MatrixDisplay(
                key: keyed.keys[info.id] ?? info.uuid, number: index + 1,
                title: info.isMain
                    ? String(localized: "Main display", comment: "Layouts window: the display with the menu bar")
                    : String(localized: "Display \(index + 1)", comment: "Layouts window: a display, by number"),
                detail: Self.size(info), orientation: info.orientation, area: info.visibleFrame)
        }
        if let runtime = pane.runtime() {
            table = await runtime.assignments.table
            isLocked = await runtime.assignments.isReadOnly
        } else {
            table = AssignmentTable()
            isLocked = false
        }
        await refreshLibrary()
        if focused == nil, !displays.isEmpty { focused = MatrixPosition(row: 0, column: 0) }
    }

    private static func size(_ info: DisplayInfo) -> String {
        "\(Int(info.frame.width)) × \(Int(info.frame.height))"
    }

    // MARK: Cells

    var zonesConfig: ZonesConfig {
        ZonesConfig(
            assignments: table, library: library,
            defaultLandscape: pane.settings.defaultZoneLayout(for: .landscape),
            defaultPortrait: pane.settings.defaultZoneLayout(for: .portrait))
    }

    var selectableKinds: [LayoutKind] { pane.selectableKinds }

    func kindName(_ kind: LayoutKind) -> String { pane.kindName(kind) }

    func kind(of workspace: WorkspaceID) -> LayoutKind { pane.layoutConfig.resolved(for: workspace).kind }

    func cell(workspace: WorkspaceID, display: MatrixDisplay) -> MatrixCell {
        let resolved = zonesConfig.resolve(
            workspace: workspace, displayKey: display.key, orientation: display.orientation)
        let name = StockLayouts.displayName(of: resolved.layout)
        let label: String
        switch resolved.source {
        case .assigned: label = name
        case .assignedForShape:
            label = String(
                localized: "\(name) · by shape",
                comment: "Layouts window: a layout chosen for every display of one shape")
        case .defaultOfShape, .builtIn:
            label = String(localized: "\(name) · default", comment: "Layouts window: the layout comes from the default")
        }
        return MatrixCell(
            workspace: workspace, displayKey: display.key,
            assignedID: table.layoutID(workspace: workspace, displayKey: display.key), effective: resolved,
            label: label, isInactive: !(pane.registry[kind(of: workspace)]?.usesLayoutLibrary ?? false))
    }

    /// The cells whose layout was missing, so the default was used (the pane reports it).
    var fallbackCount: Int {
        workspaces.reduce(0) { total, workspace in
            total + displays.filter { cell(workspace: workspace, display: $0).effective.fellBack }.count
        }
    }

    /// The menu entry that gives a cell back to the default: "Use default (Columns 2)".
    func defaultTitle(for display: MatrixDisplay) -> String {
        let id = zonesConfig.defaultID(for: display.orientation)
        let name = library.layout(id).map(StockLayouts.displayName(of:)) ?? ""
        return String(
            localized: "Use default (\(name))", comment: "Layouts window: the menu entry that clears a choice")
    }

    func name(of layout: GridLayout) -> String { StockLayouts.displayName(of: layout) }

    // MARK: Layout facts for the detail card

    /// How many cells explicitly use a layout.
    func usage(of layoutID: String) -> Int { table.count(using: layoutID) }

    /// The second line of a sidebar row: "Grid · 3 zones · used on 2 cells".
    func rowDetail(of layout: GridLayout) -> String {
        let cells = usage(of: layout.id)
        let used =
            cells == 0
            ? String(localized: "Not assigned", comment: "Layouts window: no cell uses this layout")
            : String(localized: "Used on \(cells) cells", comment: "Layouts window: how many cells use this layout")
        return "\(detail(of: layout)) · \(used)"
    }

    func detail(of layout: GridLayout) -> String {
        let zones = String(
            localized: "\(layout.zones.count) zones", comment: "Layouts window: how many zones a layout has")
        let kind = String(localized: "Grid", comment: "Layouts window: the style of a layout")
        return "\(kind) · \(zones)"
    }

    func usageText(of layout: GridLayout) -> String {
        var parts: [String] = []
        let cells = usage(of: layout.id)
        parts.append(
            cells == 0
                ? String(localized: "Not assigned", comment: "Layouts window: no cell uses this layout")
                : String(localized: "Used on \(cells) cells", comment: "Layouts window: how many cells use this layout")
        )
        let held = slots(of: layout.id)
        if !held.isEmpty {
            parts.append(
                String(
                    localized: "Slot \(held.map(String.init).joined(separator: ", "))",
                    comment: "Layouts window: the shortcut slots a layout is bound to"))
        }
        if pane.settings.defaultZoneLayout(for: .landscape) == layout.id {
            parts.append(
                String(localized: "Default for landscape displays", comment: "Layouts window: the layout is a default"))
        }
        if pane.settings.defaultZoneLayout(for: .portrait) == layout.id {
            parts.append(
                String(localized: "Default for portrait displays", comment: "Layouts window: the layout is a default"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Changing

    /// Sets (or with `nil` clears) the layout of one cell.
    func setLayout(_ layoutID: String?, workspace: WorkspaceID, displayKey: String) async {
        await write([(workspace, displayKey, layoutID)])
    }

    /// *Apply to…*: writes one layout to a set of cells.
    func apply(_ layoutID: String, to target: ApplyTarget) async {
        var changes: [(WorkspaceID, String, String?)] = []
        for workspace in workspaces {
            for display in displays {
                switch target {
                case .everything: break
                case .display(let key): guard key == display.key else { continue }
                case .workspace(let only): guard only == workspace else { continue }
                }
                changes.append((workspace, display.key, layoutID))
            }
        }
        await write(changes)
    }

    private func write(_ changes: [(WorkspaceID, String, String?)]) async {
        guard canEdit, !changes.isEmpty, let runtime = pane.runtime() else { return }
        do {
            try await runtime.assignments.setAll(changes.map { (workspace: $0.0, displayKey: $0.1, layoutID: $0.2) })
            writeFailed = false
        } catch {
            writeFailed = true
            runtime.context.logger.error("Cannot write assignments.json")
        }
        table = await runtime.assignments.table
        await runtime.applySettings()
        runtime.context.resultsChanged()
    }

    /// The stored overrides come from a newer version and cannot be changed.
    var overridesLocked: Bool { pane.overridesLocked }

    func setKind(_ kind: LayoutKind, for workspace: WorkspaceID) {
        // A kind equal to the default is stored as no override, like the *Toggle layout* command does.
        pane.setOverrideKind(kind == pane.defaultKind ? nil : kind, for: workspace)
    }

    func identify(_ display: MatrixDisplay) { identifier(display) }

    // MARK: Summary

    /// "6 layouts · Zones on 2 workspaces", the line under *Layouts…* in Settings.
    var summary: String { pane.layoutsSummary }

    // MARK: Keyboard

    /// What a key does to the matrix (the table in `LayoutsModelTests`). Arrows stop at the edges.
    func handle(_ key: MatrixKey) async {
        let rows = workspaces.count
        let columns = displays.count
        guard rows > 0, columns > 0 else { return }
        var position = focused ?? MatrixPosition(row: 0, column: 0)
        position.row = min(max(position.row, 0), rows - 1)
        position.column = min(max(position.column, 0), columns - 1)
        switch key {
        case .left: position.column = max(0, position.column - 1)
        case .right: position.column = min(columns - 1, position.column + 1)
        case .up: position.row = max(0, position.row - 1)
        case .down: position.row = min(rows - 1, position.row + 1)
        case .clear:
            focused = position
            await setLayout(nil, workspace: workspaces[position.row], displayKey: displays[position.column].key)
            return
        case .layout(let number):
            focused = position
            guard number >= 1, number <= stockLayouts.count else { return }
            await setLayout(
                stockLayouts[number - 1].id, workspace: workspaces[position.row],
                displayKey: displays[position.column].key)
            return
        }
        focused = position
    }
}
