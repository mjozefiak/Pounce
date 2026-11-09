import CoreGraphics
import Foundation
import LintelKit

/// What was sampled from the mouse and keyboard at one moment (spec: step 3.5a): whether the left button is
/// down, whether Shift is held, and where the cursor is, in the Accessibility coordinate space (origin at the
/// top left of the main display) like every frame in the engine.
struct PointerSample: Equatable, Sendable {
    var leftButtonDown: Bool
    var shiftDown: Bool
    var cursor: CGPoint
}

/// One zone the overlay offers: the display it is on (`DisplayKeys`), the zone id and number of the layout shown
/// there, and its frame in the Accessibility space.
struct DragZone: Equatable, Hashable, Sendable {
    var displayKey: String
    var zoneID: Int
    var number: Int
    var frame: CGRect
}

/// The zones of one display with the display's usable area; a cursor inside the area picks a zone of that
/// display (the nearest one when it is in a gap between zones).
struct DragDisplay: Equatable, Sendable {
    var key: String
    var area: CGRect
    var zones: [DragZone]
}

enum DragInput: Equatable, Sendable {
    /// A managed window of a Zones workspace moved (an Accessibility moved event that is not our own echo), with
    /// the pointer sampled at that moment. This is the only input that can start a drag.
    case windowMoved(WindowID, PointerSample)
    /// The pointer changed while a drag is going on (a timer or a mouse monitor); ignored when there is no drag.
    case pointer(PointerSample)
    /// The zones to offer, sent after the machine asked to show the overlay (and again when displays change).
    case displays([DragDisplay])
    case windowGone(WindowID)
    case cancel
}

enum DragEffect: Equatable, Sendable {
    /// Show the zone overlay for this window; the controller answers with `.displays`.
    case showOverlay(WindowID)
    case hideOverlay
    /// The zone under the cursor changed (`nil`: none).
    case highlight(DragZone?)
    /// The button was released over a zone with Shift still held: snap the window there.
    case snap(WindowID, DragZone)
}

/// When the snap overlay is wanted (spec: step 3.5a, Q15): only while a *managed window's* moved events arrive
/// with the left button down and Shift held, so a text selection, a Finder drag or a window the engine moved
/// itself never shows it. Releasing the button over a zone snaps; releasing Shift, or the button away from every
/// zone, cancels without moving anything. Pure: time and events arrive as inputs, effects are returned.
struct ZoneDragMachine: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        /// The window is being dragged with the button down and the overlay is not shown.
        case dragging(WindowID)
        /// The overlay is shown for the window.
        case overlay(WindowID)
    }

    private(set) var phase = Phase.idle
    private(set) var displays: [DragDisplay] = []
    private(set) var highlighted: DragZone?
    private var cursor: CGPoint?

    var draggedWindow: WindowID? {
        switch phase {
        case .idle: nil
        case .dragging(let id), .overlay(let id): id
        }
    }

    var isOverlayVisible: Bool {
        if case .overlay = phase { return true }
        return false
    }

    mutating func handle(_ input: DragInput) -> [DragEffect] {
        switch input {
        case .windowMoved(let id, let sample):
            switch phase {
            case .idle:
                guard sample.leftButtonDown else { return [] }
                return sample.shiftDown ? beginOverlay(id, sample) : begin(id)
            case .dragging(let current), .overlay(let current):
                // Another window's events (an app animating its own windows) do not disturb the drag.
                guard current == id else { return [] }
                return follow(sample)
            }
        case .pointer(let sample):
            guard phase != .idle else { return [] }
            return follow(sample)
        case .displays(let next):
            displays = next
            guard isOverlayVisible, let cursor else { return [] }
            return updateHighlight(at: cursor)
        case .windowGone(let id):
            guard draggedWindow == id else { return [] }
            return finish(snapping: nil)
        case .cancel:
            guard phase != .idle else { return [] }
            return finish(snapping: nil)
        }
    }

    // MARK: Transitions

    private mutating func begin(_ id: WindowID) -> [DragEffect] {
        phase = .dragging(id)
        return []
    }

    private mutating func beginOverlay(_ id: WindowID, _ sample: PointerSample) -> [DragEffect] {
        phase = .overlay(id)
        cursor = sample.cursor
        return [.showOverlay(id)] + updateHighlight(at: sample.cursor)
    }

    /// A sample while a drag is going on.
    private mutating func follow(_ sample: PointerSample) -> [DragEffect] {
        guard let id = draggedWindow else { return [] }
        cursor = sample.cursor
        guard sample.leftButtonDown else {
            // Released: over a zone with the overlay up, the window snaps; anywhere else nothing happens.
            if isOverlayVisible, sample.shiftDown, let zone = zone(at: sample.cursor) {
                return finish(snapping: (id, zone))
            }
            return finish(snapping: nil)
        }
        switch phase {
        case .idle:
            return []
        case .dragging:
            return sample.shiftDown ? beginOverlay(id, sample) : []
        case .overlay:
            guard sample.shiftDown else {
                // Shift let go: the overlay goes, the drag goes on as a plain window drag.
                phase = .dragging(id)
                highlighted = nil
                return [.hideOverlay]
            }
            return updateHighlight(at: sample.cursor)
        }
    }

    private mutating func finish(snapping: (WindowID, DragZone)?) -> [DragEffect] {
        var effects: [DragEffect] = []
        if isOverlayVisible { effects.append(.hideOverlay) }
        if let snapping { effects.append(.snap(snapping.0, snapping.1)) }
        phase = .idle
        highlighted = nil
        cursor = nil
        displays = []
        return effects
    }

    private mutating func updateHighlight(at point: CGPoint) -> [DragEffect] {
        let zone = zone(at: point)
        guard zone != highlighted else { return [] }
        highlighted = zone
        return [.highlight(zone)]
    }

    // MARK: Hit test

    /// The zone under a point: the display whose area holds the cursor, then the zone whose frame holds it, else
    /// the nearest zone of that display (a cursor in the gap between zones still has a target).
    func zone(at point: CGPoint) -> DragZone? {
        guard let display = displays.first(where: { $0.area.contains(point) }) else { return nil }
        if let hit = display.zones.first(where: { $0.frame.contains(point) }) { return hit }
        var best: (zone: DragZone, distance: CGFloat)?
        for zone in display.zones {
            let dx = max(zone.frame.minX - point.x, 0, point.x - zone.frame.maxX)
            let dy = max(zone.frame.minY - point.y, 0, point.y - zone.frame.maxY)
            let distance = dx * dx + dy * dy
            if best == nil || distance < best?.distance ?? .infinity { best = (zone, distance) }
        }
        return best?.zone
    }
}
