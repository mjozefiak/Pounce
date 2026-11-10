import CoreGraphics
import Foundation
import LintelKit
import Synchronization
import Testing

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
        var echoes = false
        var deliversEvents = true
        var available = true
        var stalled = 0
        var snapshotHoldArmed = false
        /// Processes whose window LIST read fails while a role probe would still answer (F3).
        var listFailsPids: Set<Int32> = []
        /// Windows the app lists but whose attributes cannot be read (F2).
        var unreadableIDs: Set<WindowID> = []
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
    private let terminatedFlag = TerminationFlag()
    let events: AsyncStream<WindowEvent>
    private let continuation: AsyncStream<WindowEvent>.Continuation

    init(displays: [DisplayInfo] = [FakeWindowClient.mainDisplay], windows: [WindowInfo] = []) {
        (events, continuation) = AsyncStream.makeStream(of: WindowEvent.self, bufferingPolicy: .bufferingNewest(1_000))
        state.withLock {
            $0.displays = displays
            for window in windows { $0.windows[window.id] = window }
        }
        let flag = terminatedFlag
        continuation.onTermination = { _ in flag.value.withLock { $0 = true } }
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
    /// With `false` the fake emits no events of its own (echoes, snap-backs): a test then feeds the engine exactly
    /// the events it means to, in the order it means to.
    func setDeliversEvents(_ delivers: Bool) { state.withLock { $0.deliversEvents = delivers } }
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
    /// Whether the event stream has ended (its consumer is gone).
    var eventsTerminated: Bool { terminatedFlag.value.withLock { $0 } }
    /// The order in which the engine used the port: `subscribe`, `windows`, `window`.
    var callLog: [String] { state.withLock { $0.log } }
    var focusCalls: [WindowID] { state.withLock { $0.focusCalls } }
    func frame(of id: WindowID) -> CGRect? { state.withLock { $0.windows[id]?.frame } }
    func clearCalls() { state.withLock { $0.calls = [] } }

    // MARK: WindowClient

    var availability: WindowClientAvailability {
        state.withLock { $0.available ? .available : .unsupported(reason: "scripted") }
    }

    func windows() async -> [WindowInfo] {
        let (list, hold) = state.withLock { state -> ([WindowInfo], Bool) in
            state.log.append("windows")
            state.windowsReads += 1
            let hold = state.snapshotHoldArmed
            state.snapshotHoldArmed = false
            // An app that does not answer shows no windows (like the real client's failed read).
            let readable = state.windows.values.filter {
                state.behaviorsByProcess[$0.id.pid] != .hung && !state.listFailsPids.contains($0.id.pid)
                    && !state.unreadableIDs.contains($0.id)
            }
            return (readable.sorted { $0.id < $1.id }, hold)
        }
        if hold { await holdUntilReleased() }
        return list
    }

    /// The window list of this process times out while it still answers a role probe (`isResponding` stays true).
    func setListFails(_ failing: Bool, forProcess pid: Int32) {
        state.withLock { if failing { $0.listFailsPids.insert(pid) } else { $0.listFailsPids.remove(pid) } }
    }

    /// The app lists this window but its attributes cannot be read.
    func setUnreadable(_ unreadable: Bool, _ id: WindowID) {
        state.withLock { if unreadable { $0.unreadableIDs.insert(id) } else { $0.unreadableIDs.remove(id) } }
    }

    /// The same verdicts the real client gives from the read itself: a hung app or a failing list is `unreachable`,
    /// an unreadable window is `unreadable`; neither depends on `isResponding`.
    func readWindows(tracked: Set<Int32>) async -> WindowRead {
        let list = await windows()
        let (unreachable, unreadable) = state.withLock { state -> (Set<Int32>, Set<WindowID>) in
            var pids = state.listFailsPids
            for (pid, behavior) in state.behaviorsByProcess where behavior == .hung { pids.insert(pid) }
            let present = Set(state.windows.keys.map(\.pid))
            return (pids.intersection(present), state.unreadableIDs.filter { state.windows[$0] != nil })
        }
        // Like the real client: every app that did not answer is `unreachable`, but only the unreadable windows of
        // tracked processes are reported.
        return WindowRead(
            windows: list, unreachable: unreachable,
            unreadable: unreadable.filter { tracked.contains($0.pid) })
    }

    /// The next `windows()` call (the engine's first snapshot) answers only after `releaseReadHold()`.
    func armSnapshotHold() { state.withLock { $0.snapshotHoldArmed = true } }

    private func holdUntilReleased() async {
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

    func window(id: WindowID) async -> WindowInfo? {
        let (info, hold) = state.withLock { state -> (WindowInfo?, Bool) in
            state.singleReads += 1
            state.log.append("window")
            let hold = state.readHoldArmed
            state.readHoldArmed = false
            return (state.behaviorsByProcess[id.pid] == .hung ? nil : state.windows[id], hold)
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
        let behavior = state.withLock { state -> Behavior in
            state.calls.append(Call(id: id, frame: frame))
            wake = state.callWaiters.filter { $0.count <= state.calls.count }.map(\.continuation)
            state.callWaiters.removeAll { $0.count <= state.calls.count }
            return state.behaviors[id] ?? state.behaviorsByProcess[id.pid] ?? .normal
        }
        for waiter in wake { waiter.resume() }
        defer {
            let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
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
            return (actual, state.echoes && state.deliversEvents, state.deliversEvents ? snap : nil)
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
    private var sleeperWaiters: [(id: UUID, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var nextID: UInt64 = 0
    private let autoAdvance: Bool
    /// How many sleeps an auto-advancing clock has answered at once. A timed loop that re-arms itself on such a clock
    /// never lets time pass, so it spins until the test ends (and starves the other tests of a small CI runner). Past
    /// this many the clock records a failure and cancels the sleep instead of letting it spin.
    private var autoAdvancedSleeps = 0
    static let autoAdvanceLimit = 20_000

    init(start: Double = 10_000, autoAdvance: Bool = true) {
        current = Instant(offset: .seconds(start))
        self.autoAdvance = autoAdvance
    }

    var now: Instant { lock.withLock { current } }

    /// How many tasks are asleep on this clock right now (a timer that is armed).
    var sleeperCount: Int { lock.withLock { sleepers.count } }
    var minimumResolution: Duration { .zero }

    /// The time in seconds, for the inputs a test builds by hand.
    var seconds: Double {
        let parts = now.offset.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Waits until `count` tasks are asleep on this clock (deterministic: no polling).
    func waitForSleepers(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if sleepers.count >= count { return true }
                sleeperWaiters.append((UUID(), count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// `waitForSleepers` that gives up after `limit` of real time and records an `Issue` instead of hanging the run.
    /// Returns whether the sleepers arrived.
    @discardableResult
    func waitForSleepers(
        _ count: Int, limit: Duration, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        let id = UUID()
        let timedOut = Mutex(false)
        let watchdog = Task { [weak self] in
            try? await ContinuousClock().sleep(for: limit)
            guard !Task.isCancelled, let self else { return }
            let waiter = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard let index = self.sleeperWaiters.firstIndex(where: { $0.id == id }) else { return nil }
                return self.sleeperWaiters.remove(at: index).continuation
            }
            if let waiter {
                timedOut.withLock { $0 = true }
                waiter.resume()
            }
        }
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if sleepers.count >= count { return true }
                sleeperWaiters.append((id, count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
        watchdog.cancel()
        let failed = timedOut.withLock { $0 }
        if failed {
            Issue.record(
                "no \(count) sleeper(s) arrived within \(limit): the code under test never armed its timer",
                sourceLocation: sourceLocation)
        }
        return !failed
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
        let (immediate, runaway) = lock.withLock { () -> (Bool, Bool) in
            if deadline <= current { return (true, false) }
            if autoAdvance {
                current = deadline
                autoAdvancedSleeps += 1
                return (true, autoAdvancedSleeps == Self.autoAdvanceLimit + 1)
            }
            return (false, false)
        }
        if lock.withLock({ autoAdvancedSleeps > Self.autoAdvanceLimit }) {
            if runaway {
                Issue.record(
                    "an auto-advancing virtual clock answered \(Self.autoAdvanceLimit) sleeps: a timed loop re-arms itself without time passing; give the test a clock that does not auto-advance (autoTick: false) and drive the timer by hand"
                )
            }
            throw CancellationError()
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
                let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    let ready = sleeperWaiters.filter { $0.count <= sleepers.count }.map(\.continuation)
                    sleeperWaiters.removeAll { $0.count <= sleepers.count }
                    return ready
                }
                for waiter in ready { waiter.resume() }
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

final class TerminationFlag: Sendable {
    let value = Mutex(false)
}
