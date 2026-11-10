import ApplicationServices
import Foundation
import LintelKit
import Testing

@testable import LintelApp

/// Step 1.8b: the pure parts of the AX observation (the buffer between the callbacks and the stream, the
/// notification mapping and the choice of observed apps). Real observers are a manual item (`docs/qa.md`).
@Suite struct AXEventBufferTests {
    private func id(_ number: UInt32, pid: Int32 = 10) -> WindowID { WindowID(pid: pid, number: number) }

    /// Collects what was delivered; the stream is finished so the loop ends.
    private func delivered(_ body: (AXEventBuffer) -> Void, capacity: Int = 1_024) async -> [WindowEvent] {
        let (stream, buffer) = AXEventBuffer.make(capacity: capacity)
        body(buffer)
        buffer.finish()
        var result: [WindowEvent] = []
        for await event in stream { result.append(event) }
        return result
    }

    @Test func eventsArriveInOrderAndNothingIsMergedOrDropped() async {
        let sent: [WindowEvent] = [
            .created(id(1)), .moved(id(1)), .moved(id(1)), .focused(id(1)), .destroyed(id(1)), .created(id(2)),
        ]
        let events = await delivered { buffer in for event in sent { buffer.append(event) } }
        #expect(events == sent)
    }

    @Test func anOverflowIsFollowedByAResyncInsteadOfSilentLoss() async {
        let events = await delivered(
            { buffer in
                buffer.append(.destroyed(id(1)))
                for number in 2...20 { buffer.append(.moved(id(UInt32(number)))) }
            }, capacity: 4)
        // The oldest events are gone (the destroyed one among them), so a resync is queued behind them.
        #expect(!events.contains(.destroyed(id(1))))
        #expect(events.contains(.resync))
    }

    @Test func notificationsMapToEvents() {
        func event(_ name: String, _ number: UInt32?) -> WindowEvent? {
            AXNotificationMapper.event(for: name, pid: 7, windowNumber: number)
        }
        let window = WindowID(pid: 7, number: 5)
        #expect(event(kAXWindowCreatedNotification, 5) == .created(window))
        #expect(event(kAXUIElementDestroyedNotification, 5) == .destroyed(window))
        #expect(event(kAXMovedNotification, 5) == .moved(window))
        #expect(event(kAXResizedNotification, 5) == .resized(window))
        #expect(event(kAXWindowMiniaturizedNotification, 5) == .created(window))
        #expect(event(kAXWindowDeminiaturizedNotification, 5) == .created(window))
        #expect(event(kAXFocusedWindowChangedNotification, 5) == .focused(window))
        #expect(event(kAXFocusedWindowChangedNotification, nil) == .focused(nil))
        // A number that could not be read drops everything but a focus change; unknown names are ignored.
        #expect(event(kAXMovedNotification, nil) == nil)
        #expect(event(kAXWindowCreatedNotification, nil) == nil)
        #expect(event("AXSomethingElse", 5) == nil)
    }

    @Test func onlyRegularLiveAppsOtherThanLintelAreObserved() {
        let apps = [
            AppObservationPlan.App(pid: 1, isRegular: true),
            AppObservationPlan.App(pid: 2, isRegular: false),
            AppObservationPlan.App(pid: 3, isRegular: true, isTerminated: true),
            AppObservationPlan.App(pid: 4, isRegular: true),
            AppObservationPlan.App(pid: 0, isRegular: true),
        ]
        #expect(AppObservationPlan.pids(for: apps, ownPID: 4) == [1])
        let changes = AppObservationPlan.changes(from: [1, 9], to: [1, 5, 6])
        #expect(changes.add == [5, 6])
        #expect(changes.remove == [9])
    }
}
