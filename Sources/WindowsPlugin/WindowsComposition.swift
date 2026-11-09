import Foundation
import LintelKit

/// The parts of the plugin that need a display or the pointer: the menu bar strip and the snap overlay with its
/// drag detector. They are built by factories the runtime calls, so a runtime in a test that passes none touches
/// neither a status item nor a panel.
@MainActor
struct WindowsComposition {
    var makeStrip: (@MainActor (WindowsRuntime) -> WorkspaceStripController)?
    var makeDragController: (@MainActor (WindowsRuntime) -> ZoneDragController)?
    /// Releases the overlay panels when the runtime stops.
    var tearDownOverlay: @MainActor () -> Void = {}

    static func parts(showsStrip: Bool, showsOverlay: Bool) -> WindowsComposition {
        var parts = WindowsComposition()
        if showsStrip {
            parts.makeStrip = { runtime in
                WorkspaceStripController(
                    select: { number in
                        guard let workspace = WorkspaceID(number) else { return }
                        Task { await runtime.goToWorkspace(workspace) }
                    },
                    restoreAll: { Task { await runtime.restoreAllWindows() } })
            }
        }
        if showsOverlay {
            let panels = ZoneOverlayPanels()
            parts.tearDownOverlay = { panels.tearDown() }
            parts.makeDragController = { runtime in
                ZoneDragController(
                    sampler: SystemPointerSampler(), presenter: panels, ticker: TimerDragTicker(),
                    targets: { [engine = runtime.engine] id in await engine.dragDisplays(for: id) },
                    snap: { [weak runtime] id, zone in await runtime?.snap(id, to: zone) })
            }
        }
        return parts
    }
}
