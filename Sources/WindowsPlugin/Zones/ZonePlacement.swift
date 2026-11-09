import CoreGraphics
import Foundation
import LintelKit

/// Which zone each window of one workspace sits in, on one display (spec: Data Model, `zones: { displayKey ->
/// { windowID -> zoneID } }`). Several windows may share a zone: they stack, the focused one on top.
struct ZoneState: Equatable, Sendable {
    var zoneOf: [WindowID: Int] = [:]

    var isEmpty: Bool { zoneOf.isEmpty }

    /// The windows in a zone in a stable order.
    func windows(in zone: Int) -> [WindowID] {
        zoneOf.filter { $0.value == zone }.map(\.key).sorted()
    }
}

/// The zone placement of one workspace, per display key (state kind `zones`). Windows of other displays keep their
/// placement while a display shows another layout.
struct ZonesLayoutState: LayoutStateValue, Equatable {
    var byDisplay: [String: ZoneState] = [:]

    var isEmpty: Bool { byDisplay.isEmpty }
}

/// The pure rules of one grid layout (kind `zones`): where a new window goes, the frames (every window of a zone
/// gets the zone's frame) and the moves between zones. The layout it works on comes from the assignment of the
/// workspace and display (`ZonesConfig.resolve`).
struct ZonePlacement: Sendable {
    var layout: GridLayout

    func frames(state: ZoneState, area: CGRect) -> [WindowID: CGRect] {
        let zoneFrames = layout.frames(in: area)
        var result: [WindowID: CGRect] = [:]
        for (window, zone) in state.zoneOf {
            if let frame = zoneFrames[zone] { result[window] = frame }
        }
        return result
    }

    // MARK: Placement

    /// Where a new window goes (spec: "the zone where the previous window of that app was last placed if that
    /// zone is empty, otherwise the first empty zone, otherwise the zone of the focused window"): `preferred` is
    /// the app's last zone, `anchor` the focused window. A layout always has a zone, so a window always lands
    /// somewhere.
    func placing(_ window: WindowID, preferred: Int?, anchor: WindowID?, into state: ZoneState) -> ZoneState {
        var next = state
        next.zoneOf[window] = nil
        let occupied = Set(next.zoneOf.values)
        if let preferred, layout.number(ofZone: preferred) != nil, !occupied.contains(preferred) {
            next.zoneOf[window] = preferred
        } else if let empty = layout.zones.first(where: { !occupied.contains($0.id) }) {
            next.zoneOf[window] = empty.id
        } else if let anchor, let zone = next.zoneOf[anchor] {
            next.zoneOf[window] = zone
        } else if let first = layout.zones.first {
            next.zoneOf[window] = first.id
        }
        return next
    }

    /// Moves a window to a zone of the layout (no change when the zone does not exist).
    func moving(_ window: WindowID, toZone zone: Int, in state: ZoneState) -> ZoneState {
        guard layout.number(ofZone: zone) != nil, state.zoneOf[window] != nil else { return state }
        var next = state
        next.zoneOf[window] = zone
        return next
    }

    /// The state without the windows that are no longer wanted. A window whose zone is not in the layout any more
    /// (the assignment changed) is also dropped: it gets a zone again by the placement rule, in a stable order.
    func pruned(_ state: ZoneState, keeping wanted: Set<WindowID>) -> ZoneState {
        var next = state
        for (window, zone) in state.zoneOf where !wanted.contains(window) || layout.number(ofZone: zone) == nil {
            next.zoneOf[window] = nil
        }
        return next
    }

    /// The zone next to a window's zone in a direction.
    func neighbourZone(of window: WindowID, _ direction: TilingDirection, in state: ZoneState) -> Int? {
        state.zoneOf[window].flatMap { layout.neighbour(of: $0, direction) }
    }
}

/// The JSON shape of one workspace's zone placement in `state.json` (`workspaces[n].zones`): per display key a
/// list of `{"window": {pid, number}, "zone": Int}`. No titles, no bundle ids.
struct ZonesRecord: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var window: WindowID
        var zone: Int
    }

    var displays: [String: [Entry]]

    init(_ zones: [String: ZoneState]) {
        displays = zones.mapValues { state in
            state.zoneOf.sorted { $0.key < $1.key }.map { Entry(window: $0.key, zone: $0.value) }
        }
    }

    var zones: [String: ZoneState] {
        var result: [String: ZoneState] = [:]
        for (key, entries) in displays where !key.isEmpty {
            var state = ZoneState()
            for entry in entries where entry.zone > 0 { state.zoneOf[entry.window] = entry.zone }
            if !state.isEmpty { result[key] = state }
        }
        return result
    }
}
