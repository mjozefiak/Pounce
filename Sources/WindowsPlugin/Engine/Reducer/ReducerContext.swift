import CoreGraphics
import Foundation
import LintelKit

/// The working state of one reduction: the new state, the effects it produced and the frame changes it wants.
/// The concerns are split into extensions in this folder.
struct ReducerContext {
    var state: EngineState
    let strategies: LayoutRegistry
    let planner: LayoutPlanner
    var effects: [EngineEffect] = []
    /// Effects that follow the journal and the frame changes (a HUD, a banner, a focus change).
    var trailing: [EngineEffect] = []
    /// Entries to journal and frame requests of this reduction, flushed in that order.
    var journal: [HiddenEntry] = []
    var requests: [FrameRequest] = []
    private var generation: Int?
    /// Set by every input that can change what a layout should do; `arrangeIfRequested` then runs once.
    var arrangeRequested = false

    init(state: EngineState, strategies: LayoutRegistry) {
        self.state = state
        self.strategies = strategies
        planner = LayoutPlanner(strategies: strategies)
    }

    // MARK: Focus

    /// Asks the system to focus `id` and remembers it as the focused window, so the next command acts on it even
    /// before the system's own focus event arrives (`PendingFocus`).
    mutating func setFocus(_ id: WindowID, now: Double) {
        state.focused = id
        state.pendingFocus = PendingFocus(id: id, expires: now + PendingFocus.lifetime)
        touchRecency(id)
        trailing.append(.focus(id))
    }

    /// Notes that `id` was the most recently used window.
    mutating func touchRecency(_ id: WindowID) {
        guard state.windows[id] != nil else { return }
        state.focusOrder.removeAll { $0 == id }
        state.focusOrder.append(id)
        if state.focusOrder.count > 256 { state.focusOrder.removeFirst(state.focusOrder.count - 256) }
    }

    mutating func forgetRecency(_ id: WindowID) {
        state.focusOrder.removeAll { $0 == id }
        if state.pendingFocus?.id == id { state.pendingFocus = nil }
    }

    /// The window of `workspace` that was focused last, else (a cold start has no history) the last in its order.
    func mostRecentWindow(in workspace: WorkspaceID, excluding: WindowID? = nil) -> WindowID? {
        for id in state.focusOrder.reversed()
        where id != excluding && state.windows[id] != nil && state.model.workspace(of: id) == workspace {
            return id
        }
        return state.model.windows(in: workspace).last { $0 != excluding && state.windows[$0] != nil }
    }

    // MARK: Batches

    mutating func request(_ id: WindowID, _ frame: CGRect, _ purpose: FramePurpose, now: Double) {
        let generation = self.generation ?? state.generation + 1
        self.generation = generation
        state.generation = generation
        state.latest[id] = generation
        state.expected[id, default: ExpectedFrames()].expect(
            generation: generation, frame: frame, expires: now + state.config.echoWindow)
        // A newer request for the same window in this reduction replaces the older one.
        requests.removeAll { $0.id == id }
        requests.append(FrameRequest(id: id, frame: frame, generation: generation, purpose: purpose))
    }

    mutating func flush() {
        if !journal.isEmpty { effects.append(.journalPark(journal)) }
        for request in requests { effects.append(.setFrame(request)) }
        effects.append(contentsOf: trailing)
        journal = []
        requests = []
        trailing = []
        generation = nil
    }
}

extension EngineState {
    /// The key of a display (its UUID, or `uuid#2` for a second display with the same UUID): the model and the
    /// layout states are keyed by it, so two identical monitors are two displays.
    func displayKey(of display: DisplayInfo) -> String { displayKeys[display.id] ?? display.uuid }

    func display(forKey key: String) -> DisplayInfo? {
        displays.first { displayKey(of: $0) == key }
    }
}
