import ApplicationServices
import Foundation
import LintelKit
import Testing

@testable import LintelApp

/// Step 1.8b: the pure parts of the AX observation (the buffer between the callbacks and the stream, the
/// notification mapping and the choice of observed apps). Real observers are a manual item (`docs/qa.md`).
@Suite struct AXEventBufferTests {
    private func id(_ number: UInt32, pid: Int32 = 10) -> WindowID { WindowID(pid: pid, number: number) }

    /// Flushes and collects what was delivered; the stream is closed through a sentinel so the loop ends.
    private func delivered(_ body: (AXEventBuffer) -> Void, capacity: Int = 256) async -> [WindowEvent] {
        let (stream, continuation) = AsyncStream.makeStream(
            of: WindowEvent.self, bufferingPolicy: .bufferingNewest(1_000))
        let buffer = AXEventBuffer(continuation: continuation, interval: nil, capacity: capacity)
        body(buffer)
        buffer.flush()
        continuation.finish()
        var result: [WindowEvent] = []
        for await event in stream { result.append(event) }
        return result
    }

    @Test func aStormOfMovesOfOneWindowBecomesOneEvent() async {
        let events = await delivered { buffer in
            for _ in 0..<500 {
                buffer.append(.moved(id(1)))
                buffer.append(.resized(id(1)))
            }
        }
        #expect(events == [.moved(id(1)), .resized(id(1))])
    }

    @Test func eventsKeepTheOrderOfTheirFirstOccurrenceAndWindowsStayApart() async {
        let events = await delivered { buffer in
            buffer.append(.moved(id(2)))
            buffer.append(.moved(id(1)))
            buffer.append(.moved(id(2)))
            buffer.append(.displaysChanged)
        }
        #expect(events == [.moved(id(2)), .moved(id(1)), .displaysChanged])
    }

    @Test func aWindowCreatedAndDestroyedInOneTickProducesNothing() async {
        let events = await delivered { buffer in
            buffer.append(.created(id(1)))
            buffer.append(.moved(id(1)))
            buffer.append(.destroyed(id(1)))
            buffer.append(.moved(id(2)))
        }
        #expect(events == [.moved(id(2))])
    }

    @Test func aDestroyedWindowKnownFromEarlierStillGetsThrough() async {
        let events = await delivered { buffer in
            buffer.append(.moved(id(1)))
            buffer.append(.destroyed(id(1)))
        }
        #expect(events == [.destroyed(id(1))])
    }

    @Test func onlyTheNewestFocusIsKeptAndItIsTheNewestEvent() async {
        let events = await delivered { buffer in
            buffer.append(.focused(id(1)))
            buffer.append(.moved(id(3)))
            buffer.append(.focused(id(2)))
            buffer.append(.focused(nil))
        }
        #expect(events == [.moved(id(3)), .focused(nil)])
    }

    @Test func theBufferIsBoundedAndDropsTheOldestMovesFirst() async {
        let events = await delivered(
            { buffer in
                buffer.append(.created(id(0)))
                for number in 1...20 { buffer.append(.moved(id(UInt32(number)))) }
                buffer.append(.spaceChanged)
            }, capacity: 5)
        #expect(events.count == 5)
        #expect(events.first == .created(id(0)))
        #expect(events.last == .spaceChanged)
    }

    @Test func aTimedBufferFlushesOnItsOwn() async {
        let (stream, continuation) = AsyncStream.makeStream(of: WindowEvent.self, bufferingPolicy: .bufferingNewest(10))
        let buffer = AXEventBuffer(continuation: continuation, interval: .milliseconds(10))
        buffer.append(.moved(id(1)))
        buffer.append(.moved(id(1)))
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .moved(id(1)))
        #expect(buffer.pendingCount == 0)
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
