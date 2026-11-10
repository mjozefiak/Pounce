import Foundation
import LintelKit

/// Merges the events that arrive between two ticks so an app that emits hundreds of move events (Electron, an
/// animation) costs one read, not hundreds. Pure: the engine flushes it on a 16 to 50 ms tick.
///
/// Rules: one pending event per (kind, window); a resize counts as a move (the engine reads the whole frame
/// anyway); only the newest `focused` event is kept; a destroyed window drops its other pending events; an app
/// that terminated drops the pending events of its windows; and when more than `capacity` distinct events pile
/// up the whole queue is replaced by one `spaceChanged`, which makes the engine look at everything again (and
/// swallows what arrives until then, because that look covers it).
struct EventCoalescer: Sendable {
    private enum Key: Hashable {
        case frame(WindowID)
        case created(WindowID)
        case destroyed(WindowID)
        case focused
        case appLaunched(Int32)
        case appTerminated(Int32)
        case displays
        case space
    }

    let capacity: Int
    private var order: [Key] = []
    private var events: [Key: WindowEvent] = [:]
    /// Events folded into an earlier one since the last drain (for diagnostics and tests).
    private(set) var mergedCount = 0

    init(capacity: Int = 1_024) {
        self.capacity = capacity
    }

    var isEmpty: Bool { order.isEmpty }
    var count: Int { order.count }

    mutating func insert(_ event: WindowEvent) {
        // A resync is pending: it reads everything again when it runs, so every other event is already covered.
        if events[.space] != nil, event != .spaceChanged { return }
        switch event {
        case .moved(let id), .resized(let id):
            put(.frame(id), .moved(id))
        case .created(let id):
            put(.created(id), event)
        case .destroyed(let id):
            discard { key in
                switch key {
                case .frame(let other), .created(let other): other == id
                default: false
                }
            }
            put(.destroyed(id), event)
        case .focused:
            put(.focused, event)
        case .appLaunched(let pid):
            put(.appLaunched(pid), event)
        case .appTerminated(let pid):
            discard { key in
                switch key {
                case .frame(let id), .created(let id), .destroyed(let id): id.pid == pid
                default: false
                }
            }
            put(.appTerminated(pid), event)
        case .displaysChanged:
            put(.displays, event)
        case .spaceChanged, .resync:
            put(.space, .spaceChanged)
        }
        if order.count > capacity {
            order = [.space]
            events = [.space: .spaceChanged]
        }
    }

    /// The pending events, oldest occurrence first, and an empty queue.
    mutating func drain() -> [WindowEvent] {
        let result = order.compactMap { events[$0] }
        order = []
        events = [:]
        mergedCount = 0
        return result
    }

    private mutating func put(_ key: Key, _ event: WindowEvent) {
        if events[key] != nil {
            order.removeAll { $0 == key }
            mergedCount += 1
        }
        order.append(key)
        events[key] = event
    }

    private mutating func discard(where matches: (Key) -> Bool) {
        let dropped = order.filter(matches)
        guard !dropped.isEmpty else { return }
        mergedCount += dropped.count
        order.removeAll(where: matches)
        for key in dropped { events[key] = nil }
    }
}
