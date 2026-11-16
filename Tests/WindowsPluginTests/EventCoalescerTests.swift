import LintelKit
import Testing

@testable import WindowsPlugin

@Suite(.timeLimit(.minutes(1))) struct EventCoalescerTests {
    private func id(_ number: UInt32, pid: Int32 = 1) -> WindowID { WindowID(pid: pid, number: number) }

    @Test func movesAndResizesOfOneWindowBecomeOne() {
        var coalescer = EventCoalescer()
        for _ in 0..<100 { coalescer.insert(.moved(id(1))) }
        coalescer.insert(.resized(id(1)))
        let drained = coalescer.drain()
        #expect(drained == [.moved(id(1))])
        #expect(coalescer.isEmpty)
    }

    @Test func eventsOfDifferentWindowsStayApartInOrderOfTheirLastOccurrence() {
        var coalescer = EventCoalescer()
        coalescer.insert(.moved(id(1)))
        coalescer.insert(.moved(id(2)))
        coalescer.insert(.moved(id(1)))
        let drained = coalescer.drain()
        #expect(drained == [.moved(id(2)), .moved(id(1))])
    }

    @Test func onlyTheNewestFocusIsKept() {
        var coalescer = EventCoalescer()
        coalescer.insert(.focused(id(1)))
        coalescer.insert(.moved(id(2)))
        coalescer.insert(.focused(id(3)))
        let drained = coalescer.drain()
        #expect(drained == [.moved(id(2)), .focused(id(3))])
    }

    @Test func aDestroyedWindowDropsItsPendingEvents() {
        var coalescer = EventCoalescer()
        coalescer.insert(.created(id(1)))
        coalescer.insert(.moved(id(1)))
        coalescer.insert(.moved(id(2)))
        coalescer.insert(.destroyed(id(1)))
        let drained = coalescer.drain()
        #expect(drained == [.moved(id(2)), .destroyed(id(1))])
    }

    @Test func aTerminatedAppDropsTheEventsOfItsWindows() {
        var coalescer = EventCoalescer()
        coalescer.insert(.moved(id(1, pid: 7)))
        coalescer.insert(.moved(id(2, pid: 8)))
        coalescer.insert(.appTerminated(pid: 7))
        let drained = coalescer.drain()
        #expect(drained == [.moved(id(2, pid: 8)), .appTerminated(pid: 7)])
    }

    @Test func displayAndSpaceChangesAreSingleEvents() {
        var coalescer = EventCoalescer()
        coalescer.insert(.displaysChanged)
        coalescer.insert(.spaceChanged)
        coalescer.insert(.displaysChanged)
        let drained = coalescer.drain()
        // The display change after the resync is covered by it and dropped.
        #expect(drained == [.displaysChanged, .spaceChanged])
    }

    @Test func aStormOfDistinctEventsCollapsesIntoAResync() {
        var coalescer = EventCoalescer(capacity: 10)
        for number in 0..<50 { coalescer.insert(.moved(id(UInt32(number)))) }
        let drained = coalescer.drain()
        #expect(drained == [.spaceChanged])
    }

    @Test func aDrainEmptiesTheQueue() {
        var coalescer = EventCoalescer()
        coalescer.insert(.appLaunched(pid: 3))
        #expect(coalescer.count == 1)
        _ = coalescer.drain()
        let rest = coalescer.drain()
        #expect(rest.isEmpty)
    }
}

@Suite(.timeLimit(.minutes(1))) struct WatchdogTests {
    @Test func staysQuietBelowTheLimit() {
        var watchdog = Watchdog(limit: 10, sustain: 2)
        for step in 0..<100 {
            let quiet = watchdog.record(now: Double(step) * 0.2)
            #expect(!quiet)
        }
    }

    @Test func aBurstThatEndsInTimeDoesNotTrip() {
        var watchdog = Watchdog(limit: 10, sustain: 2)
        for step in 0..<30 {
            let tripped = watchdog.record(now: 100 + Double(step) * 0.01)
            #expect(!tripped)
        }
        // Quiet for a while, then a normal rate again.
        let quiet = watchdog.record(now: 105)
        #expect(!quiet)
    }

    @Test func tripsAfterTheRateStaysOverTheLimitForTheSustainedTime() {
        var watchdog = Watchdog(limit: 10, sustain: 2)
        var tripped: Double?
        var now = 0.0
        while now < 5, tripped == nil {
            if watchdog.record(now: now) { tripped = now }
            now += 0.05
        }
        let at = tripped ?? -1
        #expect(at >= 2)
        #expect(at < 3)
    }

    @Test func resetForgetsTheHistory() {
        var watchdog = Watchdog(limit: 1, sustain: 0)
        let first = watchdog.record(now: 0)
        #expect(!first)
        let trip = watchdog.record(now: 0.1)
        #expect(trip)
        watchdog.reset()
        let afterReset = watchdog.record(now: 0.2)
        #expect(!afterReset)
    }
}
