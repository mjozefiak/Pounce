import CoreGraphics
import Foundation
import LintelKit

extension EngineState {
    /// The key of a display (its UUID, or `uuid#2` for a second display with the same UUID): the model and the zone
    /// state are keyed by it, so two identical monitors are two displays.
    func displayKey(of display: DisplayInfo) -> String {
        DisplayKeys.keys(for: displays).keys[display.id] ?? display.uuid
    }

    func display(forKey key: String) -> DisplayInfo? {
        let keyed = DisplayKeys.keys(for: displays).keys
        return displays.first { (keyed[$0.id] ?? $0.uuid) == key }
    }

    /// The zones the snap overlay offers for a window being dragged: the display that shows the window's
    /// workspace with the layout that workspace uses there. Nothing unless the workspace is shown, is a Zones
    /// workspace and the engine is not frozen, so the overlay never appears where a snap could not happen.
    func dragDisplays(for window: WindowID) -> [DragDisplay] {
        guard !isFrozen, windows[window] != nil, let workspace = model.workspace(of: window),
            model.isVisible(workspace), config.layout.resolved(for: workspace).kind == .zones,
            let shown = model.displayShowing(workspace), let display = display(forKey: shown)
        else { return [] }
        let key = displayKey(of: display)
        let resolved = config.zones.resolve(workspace: workspace, displayKey: key, orientation: display.orientation)
        let frames = resolved.layout.frames(in: display.visibleFrame)
        let zones = resolved.layout.zones.enumerated().compactMap { index, zone -> DragZone? in
            frames[zone.id].map { DragZone(displayKey: key, zoneID: zone.id, number: index + 1, frame: $0) }
        }
        return zones.isEmpty ? [] : [DragDisplay(key: key, area: display.visibleFrame, zones: zones)]
    }
}
