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

/// F1 (window management, resync after wake): the table from system notifications to engine events.
@Suite struct SystemEventTableTests {
    @Test func aWakeAppendsOneResyncAndAsksForAFollowUp() {
        for kind in [SystemNotificationKind.didWake, .screensDidWake] {
            #expect(SystemEventTable.events(for: kind) == [.resync])
            #expect(SystemEventTable.needsFollowUp(kind))
        }
    }

    @Test func aDisplayChangeIsAlwaysFollowedByAResync() {
        #expect(SystemEventTable.events(for: .displaysChanged) == [.displaysChanged, .resync])
        #expect(!SystemEventTable.needsFollowUp(.displaysChanged))
    }

    @Test func aSpaceChangeStaysAsItWas() {
        #expect(SystemEventTable.events(for: .spaceChanged) == [.spaceChanged])
        #expect(!SystemEventTable.needsFollowUp(.spaceChanged))
    }

    @Test func everyKindIsCovered() {
        for kind in SystemNotificationKind.allCases { #expect(!SystemEventTable.events(for: kind).isEmpty) }
    }

    @Test func theFollowUpComesAboutTwoSecondsLater() {
        #expect(SystemEventTable.followUpDelay == .seconds(2))
    }

    @Test func repeatedRequestsGiveOneDelayedResync() async {
        let (stream, buffer) = AXEventBuffer.make()
        let delayed = DelayedResync(buffer: buffer, delay: .milliseconds(50))
        delayed.schedule()
        delayed.schedule()
        delayed.schedule()
        try? await Task.sleep(for: .milliseconds(300))
        buffer.finish()
        var events: [WindowEvent] = []
        for await event in stream { events.append(event) }
        #expect(events == [.resync])
    }

    @Test func cancelStopsAPendingResync() async {
        let (stream, buffer) = AXEventBuffer.make()
        let delayed = DelayedResync(buffer: buffer, delay: .milliseconds(50))
        delayed.schedule()
        delayed.cancel()
        try? await Task.sleep(for: .milliseconds(200))
        buffer.finish()
        var events: [WindowEvent] = []
        for await event in stream { events.append(event) }
        #expect(events.isEmpty)
    }
}
