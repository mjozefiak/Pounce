import CoreGraphics
import Foundation
import LintelKit

// Results: what the engine learns when a frame change finished. A result older than the newest request for its
// window is stale and dropped.

extension ReducerContext {
    mutating func applied(_ results: [FrameResult], now: Double) {
        var cleared = Set<WindowID>()
        for result in results {
            let request = result.request
            let id = request.id
            if let newest = state.latest[id], request.generation < newest { continue }
            switch result.outcome {
            case .applied(let actual):
                state.expected[id, default: ExpectedFrames()].expect(
                    generation: request.generation, frame: actual, expires: now + state.config.echoWindow)
                if state.windows[id] != nil { state.windows[id]?.frame = actual }
                switch request.purpose {
                case .park:
                    state.parked[id]?.parkedFrame = actual
                case .restore:
                    state.parked[id] = nil
                    cleared.insert(id)
                    checkSize(request, actual: actual, now: now)
                case .place:
                    checkSize(request, actual: actual, now: now)
                }
            case .failed(let error):
                failed(request, error, cleared: &cleared)
            case .blocked:
                unpark(id)
                state.diagnostics.refusedParks += 1
                state.canJournal = false
                trailing.append(.banner(.cannotJournal))
            }
        }
        if !cleared.isEmpty { effects.append(.journalRemove(cleared)) }
    }

    /// The frame change is leaving for the app: events that echo it from now on are ours, for the echo window.
    mutating func frameStarted(_ request: FrameRequest, now: Double) {
        // Every request in flight is stamped, not only the newest: an older frame's echo is still ours.
        state.expected[request.id]?.restamp(generation: request.generation, expires: now + state.config.echoWindow)
    }

    /// A window that was meant to be parked but was not: back to its home frame in the books.
    private mutating func unpark(_ id: WindowID) {
        if let record = state.parked[id] { state.windows[id]?.frame = record.home }
        state.parked[id] = nil
    }

    private mutating func failed(_ request: FrameRequest, _ error: WindowClientError, cleared: inout Set<WindowID>) {
        let id = request.id
        // The frame was never applied, so it must not suppress the next request for it.
        state.expected[id]?.forget(generation: request.generation)
        if error == .timedOut {
            state.diagnostics.accessibilityTimeouts += 1
            state.unresponsive.insert(id.pid)
        }
        if error == .windowGone {
            removeWindow(id)
            return
        }
        if request.purpose == .park {
            // It stayed where it was: it is not parked, so its journal entry must go.
            unpark(id)
            cleared.insert(id)
        }
        // A failed restore keeps the window parked and journaled; the next event or snapshot tries again.
    }

    /// A window that did not take the size it was given is stubborn: it is centred in its tile once and never
    /// retried.
    private mutating func checkSize(_ request: FrameRequest, actual: CGRect, now: Double) {
        let id = request.id
        let tolerance = state.config.echoTolerance
        guard
            abs(actual.width - request.frame.width) > tolerance
                || abs(actual.height - request.frame.height) > tolerance
        else { return }
        guard !state.stubborn.contains(id) else { return }
        state.stubborn.insert(id)
        state.diagnostics.stubbornWindows += 1
        var target = FrameMath.centered(size: actual.size, in: request.frame)
        if let display = FrameMath.display(for: request.frame, in: state.displays) {
            target = FrameMath.clamp(target, into: display.visibleFrame)
        }
        self.request(id, target, .place, now: now)
    }
}
