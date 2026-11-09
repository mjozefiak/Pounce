import ApplicationServices
import Foundation
import LintelKit
import Synchronization

/// Folds the callbacks of the Accessibility observers into a short list of events and hands them to the client's
/// stream on a short tick (spec: Architecture, "The event stream is bounded and filtered"). An Electron app that
/// moves a window for a second, or an animation, produces one `.moved` per window per tick instead of hundreds.
///
/// `append` may be called from any thread (the AX thread, the main thread). Events keep the order in which their
/// key first appeared; a window that is created and destroyed inside one tick produces nothing; a `.focused`
/// keeps only the newest. The buffer is bounded: past `capacity` keys the oldest moves and resizes are dropped
/// (the engine reads the live frames anyway, so a dropped move loses nothing).
nonisolated final class AXEventBuffer: Sendable {
    static let defaultInterval: Duration = .milliseconds(30)
    static let defaultCapacity = 256

    private struct Key: Hashable {
        enum Kind: Hashable {
            case created, destroyed, moved, resized, focused, appLaunched, appTerminated, displays, space
        }
        var kind: Kind
        var pid: Int32 = 0
        var number: UInt32 = 0
    }

    private struct State {
        var order: [Key] = []
        var events: [Key: WindowEvent] = [:]
        var flushScheduled = false
    }

    private let state = Mutex(State())
    private let continuation: AsyncStream<WindowEvent>.Continuation
    private let interval: Duration?
    private let capacity: Int
    private let queue = DispatchQueue(label: "com.lintelapp.windows.events", qos: .userInitiated)

    /// - Parameter interval: the flush tick; `nil` flushes only when `flush()` is called (tests).
    init(
        continuation: AsyncStream<WindowEvent>.Continuation, interval: Duration? = defaultInterval,
        capacity: Int = defaultCapacity
    ) {
        self.continuation = continuation
        self.interval = interval
        self.capacity = capacity
    }

    func append(_ event: WindowEvent) {
        let schedule = state.withLock { state -> Bool in
            Self.fold(event, into: &state, capacity: capacity)
            guard interval != nil, !state.flushScheduled, !state.order.isEmpty else { return false }
            state.flushScheduled = true
            return true
        }
        if schedule, let interval {
            let milliseconds = Int(
                interval.components.seconds * 1000 + interval.components.attoseconds / 1_000_000_000_000_000)
            queue.asyncAfter(deadline: .now() + .milliseconds(max(1, milliseconds))) { [self] in flush() }
        }
    }

    /// Hands what is pending to the stream, in order.
    func flush() {
        let events = state.withLock { state -> [WindowEvent] in
            let list = state.order.compactMap { state.events[$0] }
            state.order = []
            state.events = [:]
            state.flushScheduled = false
            return list
        }
        for event in events { continuation.yield(event) }
    }

    /// How many events are waiting (tests).
    var pendingCount: Int { state.withLock { $0.order.count } }

    private static func key(for event: WindowEvent) -> Key {
        switch event {
        case .created(let id): Key(kind: .created, pid: id.pid, number: id.number)
        case .destroyed(let id): Key(kind: .destroyed, pid: id.pid, number: id.number)
        case .moved(let id): Key(kind: .moved, pid: id.pid, number: id.number)
        case .resized(let id): Key(kind: .resized, pid: id.pid, number: id.number)
        case .focused: Key(kind: .focused)
        case .appLaunched(let pid): Key(kind: .appLaunched, pid: pid)
        case .appTerminated(let pid): Key(kind: .appTerminated, pid: pid)
        case .displaysChanged: Key(kind: .displays)
        case .spaceChanged: Key(kind: .space)
        }
    }

    private static func fold(_ event: WindowEvent, into state: inout State, capacity: Int) {
        let key = key(for: event)
        if case .destroyed(let id) = event {
            // Created and destroyed inside one tick: the engine never needs to hear of it.
            let created = Key(kind: .created, pid: id.pid, number: id.number)
            let wasCreatedHere = state.events[created] != nil
            for kind in [Key.Kind.created, .moved, .resized] {
                let stale = Key(kind: kind, pid: id.pid, number: id.number)
                if state.events[stale] != nil {
                    state.events[stale] = nil
                    state.order.removeAll { $0 == stale }
                }
            }
            if wasCreatedHere { return }
        }
        if state.events[key] == nil {
            state.order.append(key)
        } else if key.kind == .focused {
            // The newest focus wins, and it is the newest event now.
            state.order.removeAll { $0 == key }
            state.order.append(key)
        }
        state.events[key] = event
        while state.order.count > capacity {
            guard
                let index = state.order.firstIndex(where: { $0.kind == .moved || $0.kind == .resized })
            else { break }
            state.events[state.order[index]] = nil
            state.order.remove(at: index)
        }
    }
}

/// Maps an Accessibility notification to the event the engine understands.
nonisolated enum AXNotificationMapper {
    /// - Parameters:
    ///   - windowNumber: the number of the window the notification is about; `nil` when it could not be read.
    static func event(for notification: String, pid: Int32, windowNumber: UInt32?) -> WindowEvent? {
        let id = windowNumber.map { WindowID(pid: pid, number: $0) }
        switch notification {
        case kAXWindowCreatedNotification:
            return id.map(WindowEvent.created)
        case kAXUIElementDestroyedNotification:
            return id.map(WindowEvent.destroyed)
        case kAXMovedNotification:
            return id.map(WindowEvent.moved)
        case kAXResizedNotification:
            return id.map(WindowEvent.resized)
        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            // Minimised or back: the engine looks at the window again and lets it go or manages it.
            return id.map(WindowEvent.created)
        case kAXFocusedWindowChangedNotification:
            return .focused(id)
        default:
            return nil
        }
    }

    /// The notifications observed on the application element.
    static let appNotifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification]
    /// The notifications observed on each window.
    static let windowNotifications = [
        kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ]
}

/// Which applications are observed: every regular app except Lintel itself (its panels are not for arranging) and
/// processes that have exited.
nonisolated enum AppObservationPlan {
    struct App: Equatable, Sendable {
        var pid: Int32
        var isRegular: Bool
        var isTerminated = false
    }

    static func pids(for apps: [App], ownPID: Int32) -> Set<Int32> {
        Set(apps.filter { $0.isRegular && !$0.isTerminated && $0.pid != ownPID && $0.pid > 0 }.map(\.pid))
    }

    /// What to start and what to stop to get from `current` to `wanted`.
    static func changes(from current: Set<Int32>, to wanted: Set<Int32>) -> (add: [Int32], remove: [Int32]) {
        (wanted.subtracting(current).sorted(), current.subtracting(wanted).sorted())
    }
}
