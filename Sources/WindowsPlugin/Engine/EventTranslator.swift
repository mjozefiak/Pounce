import CoreGraphics
import Foundation
import LintelKit

/// Turns the engine's coalesced events into reducer inputs, reading from the client what each needs (one window for
/// a move, every window for a snapshot). It decides nothing and keeps no state.
struct EventTranslator: Sendable {
    let client: any WindowClient

    /// - Parameter onSpaceChange: runs before a snapshot that follows a Space change or a resync (the engine
    ///   restores journal entries whose windows became visible).
    func inputs(
        for events: [WindowEvent], state: EngineState, moment: Double, now: @Sendable () -> Double,
        onSpaceChange: @Sendable () async -> Void
    ) async -> [EngineInput] {
        var inputs: [EngineInput] = []
        var infos: [WindowID: WindowInfo] = [:]
        for event in events {
            switch event {
            case .created(let id), .moved(let id), .resized(let id):
                if infos[id] == nil, let info = await client.window(id: id) { infos[id] = info }
            default:
                break
            }
        }
        for event in events {
            switch event {
            case .created(let id):
                if let info = infos[id] {
                    inputs.append(.windowAppeared(info, processStart: client.processStart(of: id.pid), now: moment))
                }
            case .destroyed(let id):
                inputs.append(.windowGone(id, now: moment))
            case .moved(let id), .resized(let id):
                if let info = infos[id] {
                    if state.windows[id] != nil, EngineReducer.isManaged(info, config: state.config) {
                        inputs.append(.windowMoved(id, frame: info.frame, now: moment))
                    } else {
                        // A window the engine does not hold (yet) or no longer manages (it went fullscreen or
                        // came back from it): look at it as if it had just appeared.
                        inputs.append(
                            .windowAppeared(info, processStart: client.processStart(of: id.pid), now: moment))
                    }
                }
            case .focused(let id):
                inputs.append(.windowFocused(id, now: moment))
                // A window that got the focus may have a new title: one single read keeps the cache fresh.
                if let id, state.windows[id] != nil, let info = await client.window(id: id) {
                    inputs.append(.windowAppeared(info, processStart: nil, now: moment))
                }
            case .appTerminated(let pid):
                for id in state.windows.keys where id.pid == pid { inputs.append(.windowGone(id, now: moment)) }
            case .appLaunched:
                break
            case .displaysChanged:
                inputs.append(.displaysChanged(await client.displays(), now: moment))
            case .spaceChanged, .resync:
                await onSpaceChange()
                inputs.append(await snapshot(now: now()))
            }
        }
        return inputs
    }

    /// Everything at once: the first look, a Space change, a resync.
    func snapshot(now: Double) async -> EngineInput {
        let windows = await client.windows()
        let displays = await client.displays()
        let focused = await client.focusedWindow()
        var starts: [Int32: Double] = [:]
        for window in windows where starts[window.id.pid] == nil {
            if let start = client.processStart(of: window.id.pid) { starts[window.id.pid] = start }
        }
        return .snapshot(windows: windows, displays: displays, focused: focused, processStarts: starts, now: now)
    }
}
