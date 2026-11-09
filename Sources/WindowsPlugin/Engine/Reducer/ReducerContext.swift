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

    // MARK: Batches

    mutating func request(_ id: WindowID, _ frame: CGRect, _ purpose: FramePurpose, now: Double) {
        let generation = self.generation ?? state.generation + 1
        self.generation = generation
        state.generation = generation
        state.latest[id] = generation
        state.expected[id] = ExpectedFrame(frame: frame, expires: now + state.config.echoWindow)
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
