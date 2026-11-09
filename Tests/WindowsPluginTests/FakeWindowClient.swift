import CoreGraphics
import Foundation
import LintelKit
import Synchronization

@testable import WindowsPlugin

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
        /// The app does not answer until the test calls `releaseStalls()` (a hung app that eventually returns).
        case stall
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
        var singleReads = 0
        var focusCalls: [WindowID] = []
        var inFlight = 0
        var maxInFlight = 0
        var latency: Duration = .zero
        var echoes = false
        var available = true
        var stalled = 0
        var stallsReleased = false
        var stallContinuations: [CheckedContinuation<Void, Never>] = []
        var log: [String] = []
        var readHoldArmed = false
        var readHeld = false
        var readHeldWaiters: [CheckedContinuation<Void, Never>] = []
        var readRelease: CheckedContinuation<Void, Never>?
        var completed = 0
        var completionWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var stallWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
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

    /// Waits until `count` calls are stalled (deterministic: no polling).
    func waitUntilStalled(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool in
                if state.stalled >= count { return true }
                state.stallWaiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Waits until `count` `setFrame` calls have started (deterministic: no polling).
    func waitUntilCalls(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool in
                if state.calls.count >= count { return true }
                state.callWaiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Waits until `count` `setFrame` calls have finished (deterministic: no polling).
    func waitUntilCompleted(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool in
                if state.completed >= count { return true }
                state.completionWaiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Lets every stalled call (now and later) go on.
    func releaseStalls() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.stallsReleased = true
            let all = state.stallContinuations
            state.stallContinuations = []
            return all
        }
        for continuation in waiting { continuation.resume() }
    }

    // MARK: Observation

    var calls: [Call] { state.withLock { $0.calls } }
    var windowsReads: Int { state.withLock { $0.windowsReads } }
    var singleReads: Int { state.withLock { $0.singleReads } }
    /// The order in which the engine used the port: `subscribe`, `windows`, `window`.
    var callLog: [String] { state.withLock { $0.log } }
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
            $0.log.append("windows")
            $0.windowsReads += 1
            return $0.windows.values.sorted { $0.id < $1.id }
        }
    }

    func window(id: WindowID) async -> WindowInfo? {
        let (info, hold) = state.withLock { state -> (WindowInfo?, Bool) in
            state.singleReads += 1
            state.log.append("window")
            let hold = state.readHoldArmed
            state.readHoldArmed = false
            return (state.windows[id], hold)
        }
        if hold {
            // The read has happened; the answer is not delivered until the test lets it go.
            await withCheckedContinuation { continuation in
                let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                    state.readHeld = true
                    state.readRelease = continuation
                    defer { state.readHeldWaiters = [] }
                    return state.readHeldWaiters
                }
                for waiter in waiting { waiter.resume() }
            }
        }
        return info
    }

    /// The next `window(id:)` call answers only after `releaseReadHold()`.
    func armReadHold() { state.withLock { $0.readHoldArmed = true } }

    func waitUntilReadHeld() async {
        await withCheckedContinuation { continuation in
            let held = state.withLock { state -> Bool in
                if state.readHeld { return true }
                state.readHeldWaiters.append(continuation)
                return false
            }
            if held { continuation.resume() }
        }
    }

    func releaseReadHold() {
        let release = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.readHeld = false
            defer { state.readRelease = nil }
            return state.readRelease
        }
        release?.resume()
    }

    func subscribe() async -> AsyncStream<WindowEvent> {
        state.withLock { $0.log.append("subscribe") }
        return events
    }

    func focusedWindow() async -> WindowID? { state.withLock { $0.focused } }

    func isResponding(pid: Int32) async -> Bool {
        state.withLock { $0.behaviorsByProcess[pid] != .hung && $0.behaviorsByProcess[pid] != .stall }
    }
    func displays() async -> [DisplayInfo] { state.withLock { $0.displays } }
    func processStart(of pid: Int32) -> TimeInterval? { 1_000 + Double(pid) }

    func focus(_ id: WindowID) async throws(WindowClientError) {
        state.withLock { $0.focusCalls.append(id) }
    }

    func setFrame(_ frame: CGRect, for id: WindowID) async throws(WindowClientError) -> CGRect {
        var wake: [CheckedContinuation<Void, Never>] = []
        let (latency, behavior) = state.withLock { state -> (Duration, Behavior) in
            state.calls.append(Call(id: id, frame: frame))
            wake = state.callWaiters.filter { $0.count <= state.calls.count }.map(\.continuation)
            state.callWaiters.removeAll { $0.count <= state.calls.count }
            state.inFlight += 1
            state.maxInFlight = max(state.maxInFlight, state.inFlight)
            return (state.latency, state.behaviors[id] ?? state.behaviorsByProcess[id.pid] ?? .normal)
        }
        for waiter in wake { waiter.resume() }
        if latency > .zero { try? await Task.sleep(for: latency) }
        defer {
            let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.inFlight -= 1
                state.completed += 1
                let ready = state.completionWaiters.filter { $0.count <= state.completed }.map(\.continuation)
                state.completionWaiters.removeAll { $0.count <= state.completed }
                return ready
            }
            for waiter in ready { waiter.resume() }
        }
        if behavior == .stall {
            await withCheckedContinuation { continuation in
                let (release, ready) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                    state.stalled += 1
                    let ready = state.stallWaiters.filter { $0.count <= state.stalled }.map(\.continuation)
                    state.stallWaiters.removeAll { $0.count <= state.stalled }
                    if !state.stallsReleased { state.stallContinuations.append(continuation) }
                    return (state.stallsReleased, ready)
                }
                for waiter in ready { waiter.resume() }
                if release { continuation.resume() }
            }
        }
        switch behavior {
        case .hung: throw .timedOut
        case .refuse: throw .refused
        case .gone:
            remove(id)
            throw .windowGone
        case .normal, .snapBack, .stall:
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

/// A virtual clock: time moves only when a test advances it or, with `autoAdvance`, when something sleeps (the
/// sleep then ends at once and the clock jumps to its deadline), so no test waits in real time.
final class VirtualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        var deadline: Instant
        var continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: Instant
    private var sleepers: [UInt64: Sleeper] = [:]
    private var nextID: UInt64 = 0
    private let autoAdvance: Bool

    init(start: Double = 10_000, autoAdvance: Bool = true) {
        current = Instant(offset: .seconds(start))
        self.autoAdvance = autoAdvance
    }

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    /// The time in seconds, for the inputs a test builds by hand.
    var seconds: Double {
        let parts = now.offset.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    func advance(_ seconds: Double) {
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: .seconds(seconds))
            let ready = sleepers.filter { $0.value.deadline <= current }
            for key in ready.keys { sleepers[key] = nil }
            return Array(ready.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let immediate = lock.withLock { () -> Bool in
            if deadline <= current { return true }
            if autoAdvance {
                current = deadline
                return true
            }
            return false
        }
        if immediate {
            await Task.yield()
            return
        }
        let id = lock.withLock { () -> UInt64 in
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { sleepers[id] = Sleeper(deadline: deadline, continuation: continuation) }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}

typealias ManualNow = VirtualClock

extension WindowEngine {
    /// The whole state, read on the engine's actor.
    var snapshot: EngineState {
        get async { await inspect { $0 } }
    }
}
