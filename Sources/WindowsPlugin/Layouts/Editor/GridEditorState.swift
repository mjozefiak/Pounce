import CoreGraphics
import Foundation

/// The direction of a divider: a vertical divider separates columns (dividing a zone with it puts the halves side
/// by side), a horizontal one separates rows.
enum EditorAxis: Hashable, Sendable {
    case vertical
    case horizontal
}

/// A divider is a line between two tracks, along the whole layout: `index` is the boundary between track
/// `index - 1` and track `index`, so 1 through the track count minus one.
struct DividerRef: Hashable, Sendable {
    var axis: EditorAxis
    var index: Int
}

/// What has the keyboard focus in the editor's canvas.
enum EditorFocus: Hashable, Sendable {
    case zone(Int)
    case divider(DividerRef)
}

/// Why an edit did nothing. The window says so in words; the layout is unchanged.
enum EditorFailure: Error, Equatable, Sendable {
    case unknownZone
    case unknownDivider
    case zoneLimit
    case trackLimit
    case tooNarrow
    case nothingToMerge
    /// The selected zones do not make one rectangle.
    case notRectangle
    /// The zones on the two sides of a divider do not line up, so removing it would not leave rectangles.
    case notAligned
    /// The edge is the border of the display.
    case outerEdge
    case badValue
    case nothingToUndo
    case nothingToRedo
}

/// What a key does in the canvas (the keyboard table in `GridEditorTests`).
enum EditorKey: Equatable, Sendable {
    case tab
    case backTab
    /// S: divide the focused zone (side by side).
    case divide
    /// ⇧S: divide the other way (stacked).
    case divideOther
    case left, right, up, down
    /// Delete on a divider merges the zones next to it.
    case delete
    /// Space: add or remove the focused zone from the selection.
    case toggleSelection
    /// M: merge the selected zones.
    case merge
}

/// The pure editor: a grid layout, the selection, the focus and an undo and redo stack (spec: Proposed Solution,
/// "Layout library and editor"). Every operation either changes the layout and records one undo step, or fails
/// and changes nothing. No I/O, no UI.
struct GridEditorState: Equatable, Sendable {
    /// The smallest share of the display a track keeps when a divider moves (arrow keys, numeric fields) or a zone is
    /// divided by key (S and Shift+S, `GridEditorModel.divideFocused`): 1 % (precision for the keyboard, and the room
    /// 64 zones and 32 tracks need). `divide` enforces it only when its caller passes `minimumHalf`.
    static let minimumShare = 0.01
    /// The smallest piece a *click* may cut: 5 % of the display. Repeated clicks used to halve a sliver down to a zone
    /// nobody can use (QA round 3); a click that would go below this is refused (`.tooNarrow`).
    static let minimumClickShare = 0.05
    /// One arrow-key step.
    static let step = 0.01
    static let historyLimit = 200

    private(set) var layout: GridLayout
    /// The layout when the editor opened: what `isDirty` compares with.
    let original: GridLayout
    var selection: Set<Int> = []
    var focus: EditorFocus?
    private(set) var undoStack: [GridLayout] = []
    private(set) var redoStack: [GridLayout] = []

    init(_ layout: GridLayout) {
        self.layout = layout
        original = layout
        focus = layout.zones.first.map { .zone($0.id) }
    }

    var isDirty: Bool { layout != original }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var canSave: Bool { layout.isValid && LayoutRules.isValidName(layout.name) }

    // MARK: Geometry

    /// Cumulative edges of a track list as shares of the whole: `count + 1` values from 0 to 1.
    static func edges(_ weights: [Double]) -> [Double] {
        let total = weights.reduce(0, +)
        guard total > 0 else { return [0] }
        var result = [0.0]
        var sum = 0.0
        for weight in weights {
            sum += weight
            result.append(min(1, sum / total))
        }
        result[result.count - 1] = 1
        return result
    }

    /// A zone as shares of the display: x, y, width and height from 0 to 1.
    func rect(ofZone id: Int) -> CGRect? {
        guard let zone = layout.zones.first(where: { $0.id == id }) else { return nil }
        let xs = Self.edges(layout.columns)
        let ys = Self.edges(layout.rows)
        guard zone.colEnd < xs.count, zone.rowEnd < ys.count else { return nil }
        return CGRect(
            x: xs[zone.colStart], y: ys[zone.rowStart], width: xs[zone.colEnd] - xs[zone.colStart],
            height: ys[zone.rowEnd] - ys[zone.rowStart])
    }

    /// The position of a divider as a share of the display.
    func position(of divider: DividerRef) -> Double? {
        let edges = Self.edges(divider.axis == .vertical ? layout.columns : layout.rows)
        guard divider.index >= 1, divider.index < edges.count - 1 else { return nil }
        return edges[divider.index]
    }

    var dividers: [DividerRef] {
        let columns =
            layout.columns.count > 1 ? (1..<layout.columns.count).map { DividerRef(axis: .vertical, index: $0) } : []
        let rows = layout.rows.count > 1 ? (1..<layout.rows.count).map { DividerRef(axis: .horizontal, index: $0) } : []
        return columns + rows
    }

    // MARK: Axis plumbing

    private struct Paths {
        var tracks: WritableKeyPath<GridLayout, [Double]>
        var start: WritableKeyPath<GridZone, Int>
        var end: WritableKeyPath<GridZone, Int>
        var otherStart: KeyPath<GridZone, Int>
        var otherEnd: KeyPath<GridZone, Int>
    }

    private static func paths(_ axis: EditorAxis) -> Paths {
        switch axis {
        case .vertical:
            Paths(
                tracks: \.columns, start: \.colStart, end: \.colEnd, otherStart: \.rowStart, otherEnd: \.rowEnd)
        case .horizontal:
            Paths(
                tracks: \.rows, start: \.rowStart, end: \.rowEnd, otherStart: \.colStart, otherEnd: \.colEnd)
        }
    }

    // MARK: History

    private mutating func commit(_ next: GridLayout) {
        guard next != layout else { return }
        undoStack.append(layout)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst() }
        redoStack = []
        layout = next
        reconcile()
    }

    /// Drops a selection or a focus that no longer exists after an edit.
    private mutating func reconcile() {
        let ids = Set(layout.zones.map(\.id))
        selection = selection.intersection(ids)
        switch focus {
        case .zone(let id)?:
            if !ids.contains(id) { focus = layout.zones.first.map { .zone($0.id) } }
        case .divider(let divider)?:
            if position(of: divider) == nil { focus = layout.zones.first.map { .zone($0.id) } }
        case nil:
            focus = layout.zones.first.map { .zone($0.id) }
        }
    }

    mutating func undo() -> Result<Void, EditorFailure> {
        guard let previous = undoStack.popLast() else { return .failure(.nothingToUndo) }
        redoStack.append(layout)
        layout = previous
        reconcile()
        return .success(())
    }

    mutating func redo() -> Result<Void, EditorFailure> {
        guard let next = redoStack.popLast() else { return .failure(.nothingToRedo) }
        undoStack.append(layout)
        layout = next
        reconcile()
        return .success(())
    }

    // MARK: Name and spacing

    mutating func setName(_ name: String) {
        var next = layout
        next.name = name
        commit(next)
    }

    mutating func setSpacing(_ points: Int) -> Result<Void, EditorFailure> {
        guard (0...GridLayout.maximumSpacing).contains(points) else { return .failure(.badValue) }
        var next = layout
        next.spacing = points
        commit(next)
        return .success(())
    }

    // MARK: Divide

    /// Divides a zone with a new divider at `share` (0 to 1 across the zone, 0.5 is the middle). A zone that
    /// covers several tracks is divided at the existing boundary nearest to that point; a zone of one track
    /// splits the track.
    mutating func divide(
        zone id: Int, axis: EditorAxis, share: Double = 0.5, minimumHalf: Double? = nil
    ) -> Result<Void, EditorFailure> {
        guard let zone = layout.zones.first(where: { $0.id == id }) else { return .failure(.unknownZone) }
        guard layout.zones.count < GridLayout.maximumZones else { return .failure(.zoneLimit) }
        let p = Self.paths(axis)
        var next = layout
        let first = zone[keyPath: p.start]
        let last = zone[keyPath: p.end]
        let clamped = min(max(share.isFinite ? share : 0.5, 0.1), 0.9)
        var boundary: Int
        if last - first > 1 {
            let edges = Self.edges(next[keyPath: p.tracks])
            let target = edges[first] + clamped * (edges[last] - edges[first])
            boundary = first + 1
            for candidate in (first + 1)..<last
            where abs(edges[candidate] - target) < abs(edges[boundary] - target) {
                boundary = candidate
            }
        } else {
            guard next[keyPath: p.tracks].count < GridLayout.maximumTracks else { return .failure(.trackLimit) }
            // Neither half may be smaller than the minimum share of the display.
            let edges = Self.edges(next[keyPath: p.tracks])
            let span = edges[first + 1] - edges[first]
            guard span * min(clamped, 1 - clamped) >= (minimumHalf ?? 0) - 1e-9 else { return .failure(.tooNarrow) }
            let weight = next[keyPath: p.tracks][first]
            next[keyPath: p.tracks].replaceSubrange(first...first, with: [weight * clamped, weight * (1 - clamped)])
            boundary = first + 1
            // Zones that cover the split track now cover both halves; zones after it move one along.
            for index in next.zones.indices {
                if next.zones[index][keyPath: p.start] > first { next.zones[index][keyPath: p.start] += 1 }
                if next.zones[index][keyPath: p.end] > first { next.zones[index][keyPath: p.end] += 1 }
            }
        }
        guard let at = next.zones.firstIndex(where: { $0.id == id }) else { return .failure(.unknownZone) }
        var left = next.zones[at]
        var right = left
        left[keyPath: p.end] = boundary
        right[keyPath: p.start] = boundary
        right.id = (next.zones.map(\.id).max() ?? 0) + 1
        next.zones[at] = left
        next.zones.insert(right, at: at + 1)
        selection = [id]
        focus = .zone(id)
        commit(next)
        return .success(())
    }

    // MARK: Merge

    /// Merges the selected zones into one. They must make a rectangle.
    mutating func mergeSelection() -> Result<Void, EditorFailure> {
        let chosen = layout.zones.filter { selection.contains($0.id) }
        guard chosen.count >= 2 else { return .failure(.nothingToMerge) }
        let colStart = chosen.map(\.colStart).min() ?? 0
        let colEnd = chosen.map(\.colEnd).max() ?? 0
        let rowStart = chosen.map(\.rowStart).min() ?? 0
        let rowEnd = chosen.map(\.rowEnd).max() ?? 0
        // The zones tile the grid without overlap, so they fill the bounding box exactly when their cells add up.
        let cells = chosen.reduce(0) { $0 + ($1.colEnd - $1.colStart) * ($1.rowEnd - $1.rowStart) }
        guard cells == (colEnd - colStart) * (rowEnd - rowStart) else { return .failure(.notRectangle) }
        var next = layout
        guard let keepIndex = next.zones.firstIndex(where: { selection.contains($0.id) }) else {
            return .failure(.nothingToMerge)
        }
        let keepID = next.zones[keepIndex].id
        next.zones[keepIndex] = GridZone(
            id: keepID, colStart: colStart, colEnd: colEnd, rowStart: rowStart, rowEnd: rowEnd)
        next.zones.removeAll { selection.contains($0.id) && $0.id != keepID }
        Self.normalize(&next)
        selection = [keepID]
        focus = .zone(keepID)
        commit(next)
        return .success(())
    }

    /// Removes the boundaries no zone has an edge on, joining the two tracks around them.
    private static func normalize(_ layout: inout GridLayout) {
        for axis in [EditorAxis.vertical, .horizontal] {
            let p = paths(axis)
            var boundary = layout[keyPath: p.tracks].count - 1
            while boundary >= 1 {
                let used = layout.zones.contains {
                    $0[keyPath: p.start] == boundary || $0[keyPath: p.end] == boundary
                }
                if !used {
                    let weights = layout[keyPath: p.tracks]
                    layout[keyPath: p.tracks].replaceSubrange(
                        (boundary - 1)...boundary, with: [weights[boundary - 1] + weights[boundary]])
                    for index in layout.zones.indices {
                        if layout.zones[index][keyPath: p.start] >= boundary {
                            layout.zones[index][keyPath: p.start] -= 1
                        }
                        if layout.zones[index][keyPath: p.end] >= boundary { layout.zones[index][keyPath: p.end] -= 1 }
                    }
                }
                boundary -= 1
            }
        }
    }

    /// Delete on a divider: merges the zones on its two sides. They must line up one to one.
    mutating func removeDivider(_ divider: DividerRef) -> Result<Void, EditorFailure> {
        guard position(of: divider) != nil else { return .failure(.unknownDivider) }
        let p = Self.paths(divider.axis)
        let before = layout.zones.filter { $0[keyPath: p.end] == divider.index }
        let after = layout.zones.filter { $0[keyPath: p.start] == divider.index }
        guard !before.isEmpty, before.count == after.count else { return .failure(.notAligned) }
        var next = layout
        for left in before {
            guard
                let right = after.first(where: {
                    $0[keyPath: p.otherStart] == left[keyPath: p.otherStart]
                        && $0[keyPath: p.otherEnd] == left[keyPath: p.otherEnd]
                })
            else { return .failure(.notAligned) }
            guard let at = next.zones.firstIndex(where: { $0.id == left.id }) else { return .failure(.notAligned) }
            next.zones[at][keyPath: p.end] = right[keyPath: p.end]
            next.zones.removeAll { $0.id == right.id }
        }
        Self.normalize(&next)
        focus = before.first.map { .zone($0.id) }
        commit(next)
        return .success(())
    }

    // MARK: Move

    /// Moves a divider by `delta` (a share of the display, 0.01 is 1%). Neither neighbouring track gets smaller
    /// than 1% of the display; a move that would is shortened, and fails when there is no room at all.
    mutating func moveDivider(_ divider: DividerRef, by delta: Double) -> Result<Void, EditorFailure> {
        guard position(of: divider) != nil else { return .failure(.unknownDivider) }
        guard delta.isFinite else { return .failure(.badValue) }
        let p = Self.paths(divider.axis)
        var weights = layout[keyPath: p.tracks]
        let total = weights.reduce(0, +)
        let floor = Self.minimumShare * total
        let low = divider.index - 1
        let high = divider.index
        var change = delta * total
        // Keep both neighbours at or above the floor, but never push one that is already smaller than it.
        let room = change > 0 ? weights[high] - floor : weights[low] - floor
        if abs(change) > max(room, 0) { change = change > 0 ? max(room, 0) : -max(room, 0) }
        guard abs(change) > total * 1e-9 else { return .failure(.tooNarrow) }
        weights[low] += change
        weights[high] -= change
        var next = layout
        next[keyPath: p.tracks] = weights
        focus = .divider(divider)
        commit(next)
        return .success(())
    }

    /// Moves a divider to a share of the display (a drag).
    mutating func moveDivider(_ divider: DividerRef, to share: Double) -> Result<Void, EditorFailure> {
        guard let current = position(of: divider) else { return .failure(.unknownDivider) }
        return moveDivider(divider, by: share - current)
    }

    // MARK: Numeric fields

    enum ZoneEdge: Sendable {
        case left, right, top, bottom
    }

    /// Sets one edge of a zone to a share of the display by moving the divider there (the numeric fields of the
    /// zone list). The border of the display cannot move.
    mutating func setEdge(_ edge: ZoneEdge, ofZone id: Int, to share: Double) -> Result<Void, EditorFailure> {
        guard let zone = layout.zones.first(where: { $0.id == id }) else { return .failure(.unknownZone) }
        guard share.isFinite, (0...1).contains(share) else { return .failure(.badValue) }
        let divider: DividerRef
        switch edge {
        case .left: divider = DividerRef(axis: .vertical, index: zone.colStart)
        case .right: divider = DividerRef(axis: .vertical, index: zone.colEnd)
        case .top: divider = DividerRef(axis: .horizontal, index: zone.rowStart)
        case .bottom: divider = DividerRef(axis: .horizontal, index: zone.rowEnd)
        }
        guard position(of: divider) != nil else { return .failure(.outerEdge) }
        return moveDivider(divider, to: share)
    }

    /// The zone's x, y, width and height in whole percent, as the zone list shows and reads them.
    func percentages(ofZone id: Int) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard let rect = rect(ofZone: id) else { return nil }
        func percent(_ value: CGFloat) -> Int { Int((value * 100).rounded()) }
        return (percent(rect.minX), percent(rect.minY), percent(rect.width), percent(rect.height))
    }

    // MARK: Selection and focus

    mutating func toggleSelection(zone id: Int) {
        guard layout.zones.contains(where: { $0.id == id }) else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// Zones in order, then vertical dividers, then horizontal ones: what Tab walks through.
    var focusOrder: [EditorFocus] { layout.zones.map { .zone($0.id) } + dividers.map { .divider($0) } }

    mutating func moveFocus(forward: Bool) {
        let order = focusOrder
        guard !order.isEmpty else { return }
        guard let current = focus, let index = order.firstIndex(of: current) else {
            focus = forward ? order.first : order.last
            return
        }
        let next = forward ? (index + 1) % order.count : (index + order.count - 1) % order.count
        focus = order[next]
        // The list marks the zone the detail shows: walking onto a zone selects it alone (QA D7: the list marked
        // Zone 2 while the detail line showed Zone 1).
        if case .zone(let id) = order[next] { selection = [id] }
    }

    // MARK: Keys

    /// What a key does. `nil` when the key means nothing in this state (the window lets it pass).
    @discardableResult
    mutating func handle(_ key: EditorKey) -> Result<Void, EditorFailure>? {
        switch key {
        case .tab:
            moveFocus(forward: true)
            return .success(())
        case .backTab:
            moveFocus(forward: false)
            return .success(())
        case .divide, .divideOther:
            guard case .zone(let id)? = focus else { return nil }
            return divide(zone: id, axis: key == .divide ? .vertical : .horizontal)
        case .left, .right, .up, .down:
            guard case .divider(let divider)? = focus else { return nil }
            switch (divider.axis, key) {
            case (.vertical, .left), (.horizontal, .up): return moveDivider(divider, by: -Self.step)
            case (.vertical, .right), (.horizontal, .down): return moveDivider(divider, by: Self.step)
            default: return nil
            }
        case .delete:
            guard case .divider(let divider)? = focus else { return nil }
            return removeDivider(divider)
        case .toggleSelection:
            guard case .zone(let id)? = focus else { return nil }
            toggleSelection(zone: id)
            return .success(())
        case .merge:
            return mergeSelection()
        }
    }
}
