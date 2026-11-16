import ApplicationServices
import Foundation
import LintelKit
import Synchronization

/// Hands the callbacks of the Accessibility observers to the client's stream, in order. It is the only bound on the
/// stream (`capacity`) and it coalesces nothing: the engine owns the one coalescer (`EventCoalescer`), which merges
/// the events of a busy app on its own tick. When the stream overflows, the oldest events are gone, so a `.resync`
/// is queued behind them: the consumer then looks at every window again instead of trusting a stream that may
/// have lost a `.destroyed` or a `.focused`.
///
/// `append` may be called from any thread (the AX thread, the main thread).
nonisolated final class AXEventBuffer: Sendable {
    static let defaultCapacity = 1_024

    private let continuation: AsyncStream<WindowEvent>.Continuation

    /// The stream and the buffer that feeds it.
    static func make(capacity: Int = defaultCapacity) -> (stream: AsyncStream<WindowEvent>, buffer: AXEventBuffer) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: WindowEvent.self, bufferingPolicy: .bufferingNewest(capacity))
        return (stream, AXEventBuffer(continuation: continuation))
    }

    init(continuation: AsyncStream<WindowEvent>.Continuation) {
        self.continuation = continuation
    }

    /// Ends the stream.
    func finish() { continuation.finish() }

    /// Called once when the consumer goes away (the stream ends or its task is cancelled).
    func onTermination(_ handler: @escaping @Sendable () -> Void) {
        continuation.onTermination = { _ in handler() }
    }

    func append(_ event: WindowEvent) {
        if case .dropped = continuation.yield(event) {
            _ = continuation.yield(.resync)
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
