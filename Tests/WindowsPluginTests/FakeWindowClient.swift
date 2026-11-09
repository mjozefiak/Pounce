import CoreGraphics
import Foundation
import LintelKit
import Synchronization

/// A scriptable, in-memory `WindowClient`: latency, refusals, hung apps, minimum sizes, apps that move their
/// window back, echoes of our own frames and re-ordered events. It records every call, so a test can assert what
/// the engine did and in which order.
final class FakeWindowClient: WindowClient, Sendable {
    /// What one window does when asked to move.
    enum Behavior: Equatable, Sendable {
        case normal
        /// The app answers `.timedOut` (a hung app).
        case hung
        /// The app refuses.
        case refuse
        /// The window is gone by the time the call arrives.
        case gone
        /// The app moves the window back to this frame right after every change (and says so with an event).
        case snapBack(CGRect)
    }

    struct Call: Equatable, Sendable {
        var id: WindowID
        var frame: CGRect
    }

    private struct State {
        var windows: [WindowID: WindowInfo] = [:]
        var minimumSizes: [WindowID: CGSize] = [:]
        var behaviors: [WindowID: Behavior] = [:]
        var behaviorsByProcess: [Int32: Behavior] = [:]
        var displays: [DisplayInfo] = []
        var focused: WindowID?
        var calls: [Call] = []
        var windowsReads = 0
        var focusCalls: [WindowID] = []
        var inFlight = 0
        var maxInFlight = 0
        var latency: Duration = .zero
        var echoes = false
        var available = true
    }

    private let state = Mutex(State())
    let events: AsyncStream<WindowEvent>
    private let continuation: AsyncStream<WindowEvent>.Continuation

    init(displays: [DisplayInfo] = [FakeWindowClient.mainDisplay], windows: [WindowInfo] = []) {
        (events, continuation) = AsyncStream.makeStream(of: WindowEvent.self, bufferingPolicy: .bufferingNewest(1_000))
        state.withLock {
            $0.displays = displays
            for window in windows { $0.windows[window.id] = window }
        }
    }

    static let mainDisplay = DisplayInfo(
        id: 1, uuid: "MAIN", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055), isMain: true)

    static let secondDisplay = DisplayInfo(
        id: 2, uuid: "SECOND", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1920, y: 25, width: 1920, height: 1055))

    // MARK: Script

    func add(_ window: WindowInfo) { state.withLock { $0.windows[window.id] = window } }
    func remove(_ id: WindowID) { state.withLock { $0.windows[id] = nil } }
    func setBehavior(_ behavior: Behavior, for id: WindowID) { state.withLock { $0.behaviors[id] = behavior } }
    func setBehavior(_ behavior: Behavior, forProcess pid: Int32) {
        state.withLock { $0.behaviorsByProcess[pid] = behavior }
    }
    func setMinimumSize(_ size: CGSize, for id: WindowID) { state.withLock { $0.minimumSizes[id] = size } }
    func setLatency(_ latency: Duration) { state.withLock { $0.latency = latency } }
    func setEchoes(_ echoes: Bool) { state.withLock { $0.echoes = echoes } }
    func setFocused(_ id: WindowID?) { state.withLock { $0.focused = id } }
    func setDisplays(_ displays: [DisplayInfo]) { state.withLock { $0.displays = displays } }
    func setAvailable(_ available: Bool) { state.withLock { $0.available = available } }

    /// A window moved by the user or by its own app, without the engine asking.
    func moveBehindTheEnginesBack(_ id: WindowID, to frame: CGRect) {
        state.withLock { state in
            guard let info = state.windows[id] else { return }
            state.windows[id] = replacing(info, frame: frame)
        }
    }

    func emit(_ events: [WindowEvent]) {
        for event in events { continuation.yield(event) }
    }

    func finish() { continuation.finish() }

    // MARK: Observation

    var calls: [Call] { state.withLock { $0.calls } }
    var windowsReads: Int { state.withLock { $0.windowsReads } }
    var focusCalls: [WindowID] { state.withLock { $0.focusCalls } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }
    func frame(of id: WindowID) -> CGRect? { state.withLock { $0.windows[id]?.frame } }
    func clearCalls() { state.withLock { $0.calls = [] } }

    // MARK: WindowClient

    var availability: WindowClientAvailability {
        state.withLock { $0.available ? .available : .unsupported(reason: "scripted") }
    }

    func windows() async -> [WindowInfo] {
        state.withLock {
            $0.windowsReads += 1
            return $0.windows.values.sorted { $0.id < $1.id }
        }
    }

    func focusedWindow() async -> WindowID? { state.withLock { $0.focused } }
    func displays() async -> [DisplayInfo] { state.withLock { $0.displays } }
    func processStart(of pid: Int32) -> TimeInterval? { 1_000 + Double(pid) }

    func focus(_ id: WindowID) async throws(WindowClientError) {
        state.withLock { $0.focusCalls.append(id) }
    }

    func setFrame(_ frame: CGRect, for id: WindowID) async throws(WindowClientError) -> CGRect {
        let (latency, behavior) = state.withLock { state -> (Duration, Behavior) in
            state.calls.append(Call(id: id, frame: frame))
            state.inFlight += 1
            state.maxInFlight = max(state.maxInFlight, state.inFlight)
            return (state.latency, state.behaviors[id] ?? state.behaviorsByProcess[id.pid] ?? .normal)
        }
        if latency > .zero { try? await Task.sleep(for: latency) }
        defer { state.withLock { $0.inFlight -= 1 } }
        switch behavior {
        case .hung: throw .timedOut
        case .refuse: throw .refused
        case .gone:
            remove(id)
            throw .windowGone
        case .normal, .snapBack:
            break
        }
        let result: (actual: CGRect, echo: Bool, snap: CGRect?)? = state.withLock { state in
            guard let info = state.windows[id] else { return nil }
            var actual = frame
            if let minimum = state.minimumSizes[id] {
                actual.size = CGSize(
                    width: max(frame.width, minimum.width), height: max(frame.height, minimum.height))
            }
            state.windows[id] = replacing(info, frame: actual)
            var snap: CGRect?
            if case .snapBack(let back) = behavior {
                state.windows[id] = replacing(info, frame: back)
                snap = back
            }
            return (actual, state.echoes, snap)
        }
        guard let result else { throw .windowGone }
        if result.echo { continuation.yield(.moved(id)) }
        if result.snap != nil { continuation.yield(.moved(id)) }
        return result.actual
    }
}

private func replacing(_ info: WindowInfo, frame: CGRect) -> WindowInfo {
    WindowInfo(
        id: info.id, bundleID: info.bundleID, title: info.title, frame: frame, isStandard: info.isStandard,
        isMinimized: info.isMinimized, isFullscreen: info.isFullscreen)
}

func makeWindow(
    _ number: UInt32, pid: Int32 = 100, bundleID: String? = "com.example.app",
    frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600), standard: Bool = true,
    minimized: Bool = false, fullscreen: Bool = false
) -> WindowInfo {
    WindowInfo(
        id: WindowID(pid: pid, number: number), bundleID: bundleID, title: "secret title", frame: frame,
        isStandard: standard, isMinimized: minimized, isFullscreen: fullscreen)
}

/// A clock the test moves by hand.
final class ManualNow: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double

    init(_ value: Double = 10_000) { self.value = value }

    var now: Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        value += seconds
    }
}
