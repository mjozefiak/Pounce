#if DEBUG
import CoreGraphics
import Foundation
import LintelKit
import Synchronization

/// DEBUG-only (`--qa-windows`): a window client with five fake windows and two fake displays, so window
/// management can be driven in QA mode without touching the tester's real windows. Windows move only in memory.
nonisolated final class QAWindowClient: WindowClient, Sendable {
    private struct State {
        var windows: [WindowID: WindowInfo]
        var focused: WindowID?
    }

    private let state: Mutex<State>
    let events: AsyncStream<WindowEvent>

    static let displays = [
        DisplayInfo(
            id: 1, uuid: "QA-MAIN", frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 38, width: 1728, height: 1079), isMain: true),
        DisplayInfo(
            id: 2, uuid: "QA-SECOND", frame: CGRect(x: 1728, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1728, y: 25, width: 1920, height: 1055)),
    ]

    init() {
        let titles = ["Fake Notes", "Fake Browser", "Fake Terminal", "Fake Mail", "Fake Calendar"]
        var windows: [WindowID: WindowInfo] = [:]
        for (index, title) in titles.enumerated() {
            let id = WindowID(pid: Int32(90_000 + index), number: UInt32(9_000 + index))
            windows[id] = WindowInfo(
                id: id, bundleID: "qa.fake.app\(index)", title: title,
                frame: CGRect(x: 80 + 60 * index, y: 80 + 40 * index, width: 800, height: 560))
        }
        state = Mutex(State(windows: windows, focused: windows.keys.sorted().first))
        events = AsyncStream { $0.finish() }
    }

    var availability: WindowClientAvailability { .available }
    func windows() async -> [WindowInfo] { state.withLock { $0.windows.values.sorted { $0.id < $1.id } } }
    func focusedWindow() async -> WindowID? { state.withLock { $0.focused } }
    func displays() async -> [DisplayInfo] { Self.displays }
    func processStart(of pid: Int32) -> TimeInterval? { pid >= 90_000 ? 1_000 + Double(pid) : nil }

    func setFrame(_ frame: CGRect, for id: WindowID) async throws(WindowClientError) -> CGRect {
        try state.withLock { state throws(WindowClientError) in
            guard let info = state.windows[id] else { throw .windowGone }
            state.windows[id] = WindowInfo(
                id: id, bundleID: info.bundleID, title: info.title, frame: frame, isStandard: true)
            return frame
        }
    }

    func focus(_ id: WindowID) async throws(WindowClientError) {
        try state.withLock { state throws(WindowClientError) in
            guard state.windows[id] != nil else { throw .windowGone }
            state.focused = id
        }
    }
}
#endif
