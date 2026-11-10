import AppKit
import Foundation
import LintelKit

/// Reads the pointer: the left button, Shift and the cursor. The system's one is `SystemPointerSampler`; a script
/// stands in for it in tests.
@MainActor
protocol PointerSampling: AnyObject {
    func sample() -> PointerSample
}

/// `NSEvent`'s class properties: they need no permission (unlike a global monitor for `flagsChanged`, which is a
/// key event and needs Accessibility, and which could not consume anything anyway). The sampling only runs while a
/// drag is going on (`ZoneDragController`), so nothing polls while the user is not dragging a window.
@MainActor
final class SystemPointerSampler: PointerSampling {
    func sample() -> PointerSample {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return PointerSample(
            leftButtonDown: NSEvent.pressedMouseButtons & 1 != 0,
            shiftDown: NSEvent.modifierFlags.contains(.shift),
            cursor: ScreenSpace.axPoint(fromCocoa: NSEvent.mouseLocation, mainHeight: mainHeight))
    }
}

/// A repeating tick that runs only while a drag is going on.
@MainActor
protocol DragTicking: AnyObject {
    func start(_ fire: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
final class TimerDragTicker: DragTicking {
    private var timer: Timer?
    private let interval: TimeInterval

    init(interval: TimeInterval = 1.0 / 60) { self.interval = interval }

    func start(_ fire: @escaping @MainActor () -> Void) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            // The timer calls on the main thread, but nothing here may trap if it ever does not: hop explicitly.
            Task { @MainActor in fire() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// Shows the zones over the displays while a window is dragged. The real one is `ZoneOverlayPanels`.
@MainActor
protocol ZoneOverlayPresenting: AnyObject {
    func show(_ displays: [DragDisplay])
    /// Highlights a zone (`nil`: none); remembered while the overlay is hidden.
    func highlight(_ zone: DragZone?)
    func hide()
    /// Builds what the first overlay needs ahead of time (a no-op for a presenter that has nothing to build).
    func prewarm()
}

extension ZoneOverlayPresenting {
    func prewarm() {}
}

/// Joins the pure `ZoneDragMachine` to the world (spec: step 3.5b): the engine says a managed window of a Zones
/// workspace moved, the pointer is sampled, and while the drag goes on a timer keeps sampling, because Shift can
/// be pressed or released without the window moving. The overlay appears only when the machine asks for it; the
/// snap goes back to the engine, which does the move (so it is behind the same Accessibility gate as every other).
@MainActor
final class ZoneDragController {
    private var machine = ZoneDragMachine()
    private let sampler: any PointerSampling
    private let presenter: any ZoneOverlayPresenting
    private let ticker: any DragTicking
    private let targets: @MainActor (WindowID) async -> [DragDisplay]
    private let snap: @MainActor (WindowID, DragZone) async -> Void
    private var targetsTask: Task<Void, Never>?
    /// Snaps run one after the other, in the order the drags ended.
    private let snaps = OrderedActions()

    init(
        sampler: any PointerSampling, presenter: any ZoneOverlayPresenting, ticker: any DragTicking,
        targets: @escaping @MainActor (WindowID) async -> [DragDisplay],
        snap: @escaping @MainActor (WindowID, DragZone) async -> Void
    ) {
        self.sampler = sampler
        self.presenter = presenter
        self.ticker = ticker
        self.targets = targets
        self.snap = snap
    }

    var phase: ZoneDragMachine.Phase { machine.phase }

    /// Waits for the overlay's targets to load and for every snap to finish (tear-down and tests).
    func waitUntilIdle() async {
        await targetsTask?.value
        await snaps.waitUntilEmpty()
    }

    /// The engine reports that a managed window of a Zones workspace moved.
    func windowMoved(_ id: WindowID, frame: CGRect = .infinite) {
        apply(machine.handle(.windowMoved(id, sampler.sample(), frame: frame)))
        updateTicker()
    }

    /// Builds the overlay's panels ahead of the first drag.
    func prewarm() { presenter.prewarm() }

    /// Stops any drag and hides the overlay (the plugin is switched off).
    func cancel() {
        apply(machine.handle(.cancel))
        updateTicker()
        presenter.hide()
    }

    /// One tick of the timer.
    func tick() {
        apply(machine.handle(.pointer(sampler.sample())))
        updateTicker()
    }

    private func updateTicker() {
        if machine.phase == .idle {
            ticker.stop()
        } else {
            ticker.start { [weak self] in self?.tick() }
        }
    }

    private func apply(_ effects: [DragEffect]) {
        for effect in effects {
            switch effect {
            case .showOverlay(let id):
                targetsTask?.cancel()
                targetsTask = Task { [weak self] in await self?.showOverlay(for: id) }
            case .hideOverlay:
                targetsTask?.cancel()
                targetsTask = nil
                presenter.hide()
            case .highlight(let zone):
                presenter.highlight(zone)
            case .snap(let id, let zone):
                snaps.enqueue { [snap] in await snap(id, zone) }
            }
        }
    }

    private func showOverlay(for id: WindowID) async {
        let displays = await targets(id)
        guard !Task.isCancelled, machine.draggedWindow == id, machine.isOverlayVisible else { return }
        let effects = machine.handle(.displays(displays))
        guard !displays.isEmpty else {
            // No zones to offer (the workspace is not a Zones one any more): nothing to show.
            return
        }
        apply(effects)
        presenter.show(displays)
        presenter.highlight(machine.highlighted)
    }
}
