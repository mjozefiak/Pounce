import CoreGraphics
import Foundation
import LintelKit

/// Zones: a grid layout per workspace and display (state kind `zones`, stored as `workspaces[n].zones`). A new
/// window goes to the app's last zone if that is empty, else the first empty zone, else the focused window's
/// zone; windows of one zone stack.
struct ZonesStrategy: LayoutStrategy {
    var kind: LayoutKind { .zones }

    private func placement(_ input: LayoutInput) -> ZonePlacement {
        ZonePlacement(
            layout: input.config.zones.resolve(
                workspace: input.workspace, displayKey: input.displayKey, orientation: input.display.orientation
            ).layout)
    }

    func arrange(_ input: LayoutInput) -> LayoutArrangement {
        let placement = placement(input)
        let wanted = Set(input.windows)
        var byDisplay = input.state?.as(ZonesLayoutState.self)?.byDisplay ?? [:]
        // Other displays keep their placement, minus windows that are gone.
        for other in byDisplay.keys.sorted() where other != input.displayKey {
            var kept = byDisplay[other] ?? ZoneState()
            kept.zoneOf = kept.zoneOf.filter { wanted.contains($0.key) }
            byDisplay[other] = kept.isEmpty ? nil : kept
        }
        // A window whose zone vanished (the assignment changed) is dropped and placed again, in a stable order.
        var current = placement.pruned(byDisplay[input.displayKey] ?? ZoneState(), keeping: wanted)
        var hints = input.hints
        for id in input.windows where current.zoneOf[id] == nil {
            let anchor = [input.focused, input.previousFocus].lazy.compactMap { $0 }
                .first { $0 != id && current.zoneOf[$0] != nil }
            let preferred = input.apps[id].flatMap { hints[$0] }
            current = placement.placing(id, preferred: preferred, anchor: anchor, into: current)
            if let zone = current.zoneOf[id], let app = input.apps[id] { hints[app] = zone }
        }
        byDisplay[input.displayKey] = current.isEmpty ? nil : current
        return LayoutArrangement(
            state: AnyLayoutState(ZonesLayoutState(byDisplay: byDisplay)),
            frames: placement.frames(state: current, area: input.area), hints: hints)
    }

    func perform(_ operation: LayoutOperation, on window: WindowID, _ input: LayoutInput) -> LayoutEdit? {
        guard let stored = input.state?.as(ZonesLayoutState.self),
            let placed = stored.byDisplay[input.displayKey]
        else { return nil }
        let placement = placement(input)
        switch operation {
        case .focus(let direction):
            guard let zone = placement.neighbourZone(of: window, direction, in: placed),
                let next = placed.windows(in: zone).first
            else { return nil }
            // The focus goes to the lowest window id of the neighbouring zone, so it is stable.
            return LayoutEdit(state: AnyLayoutState(stored), focus: next, hints: input.hints)
        case .move(let direction):
            guard let zone = placement.neighbourZone(of: window, direction, in: placed) else { return nil }
            return move(window, toZone: zone, input, placement, stored, placed)
        case .slot(let number):
            guard let zone = placement.layout.zone(number: number) else { return nil }
            return move(window, toZone: zone.id, input, placement, stored, placed)
        case .snap(let slotID, let displayKey):
            guard displayKey == input.displayKey else { return nil }
            return move(window, toZone: slotID, input, placement, stored, placed)
        case .resize, .join, .toggleOrientation, .balance:
            return nil
        }
    }

    private func move(
        _ window: WindowID, toZone zone: Int, _ input: LayoutInput, _ placement: ZonePlacement,
        _ stored: ZonesLayoutState, _ placed: ZoneState
    ) -> LayoutEdit? {
        let moved = placement.moving(window, toZone: zone, in: placed)
        guard moved != placed else { return nil }
        var next = stored
        next.byDisplay[input.displayKey] = moved
        var hints = input.hints
        if let app = input.apps[window] { hints[app] = zone }
        return LayoutEdit(state: AnyLayoutState(next), focus: nil, hints: hints)
    }

    func removing(_ window: WindowID, from state: AnyLayoutState) -> AnyLayoutState {
        guard var zones = state.as(ZonesLayoutState.self) else { return state }
        for key in zones.byDisplay.keys.sorted() {
            zones.byDisplay[key]?.zoneOf[window] = nil
            if zones.byDisplay[key]?.isEmpty == true { zones.byDisplay[key] = nil }
        }
        return AnyLayoutState(zones)
    }

    func snapTargets(_ input: LayoutInput) -> [DragDisplay] {
        let resolved = input.config.zones.resolve(
            workspace: input.workspace, displayKey: input.displayKey, orientation: input.display.orientation)
        let frames = resolved.layout.frames(in: input.area)
        let zones = resolved.layout.zones.enumerated().compactMap { index, zone -> DragZone? in
            frames[zone.id].map {
                DragZone(displayKey: input.displayKey, zoneID: zone.id, number: index + 1, frame: $0)
            }
        }
        return zones.isEmpty ? [] : [DragDisplay(key: input.displayKey, area: input.area, zones: zones)]
    }

    func encode(_ state: AnyLayoutState) -> JSONValue? {
        guard let zones = state.as(ZonesLayoutState.self) else { return nil }
        return JSONValue(encoding: ZonesRecord(zones.byDisplay))
    }

    func decode(_ json: JSONValue) -> AnyLayoutState? {
        guard let zones = json.decoded(as: ZonesRecord.self)?.zones, !zones.isEmpty else { return nil }
        return AnyLayoutState(ZonesLayoutState(byDisplay: zones))
    }
}
