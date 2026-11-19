import Testing

@testable import WindowsPlugin

/// The test clock is shared by most engine tests, so a sleeper it leaks makes `sleeperCount` assertions flaky (#101).
@Suite struct VirtualClockTests {
    @Test func aSleepCancelledBeforeItIsRegisteredLeavesNoSleeperBehind() async {
        let clock = VirtualClock(autoAdvance: false)
        // Cancel the sleeping task itself after its first cancellation check and before it registers: the window a
        // cancel hits on a loaded machine.
        clock.beforeRegistration = { withUnsafeCurrentTask { $0?.cancel() } }
        let sleeping = Task { () -> Bool in
            do {
                try await clock.sleep(until: clock.now.advanced(by: .seconds(60)), tolerance: nil)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let threwCancellation = await sleeping.value
        #expect(threwCancellation)
        #expect(clock.sleeperCount == 0)
    }

    @Test func aSleepCancelledWhileAsleepIsRemovedAndThrows() async {
        let clock = VirtualClock(autoAdvance: false)
        let sleeping = Task { () -> Bool in
            do {
                try await clock.sleep(until: clock.now.advanced(by: .seconds(60)), tolerance: nil)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await clock.waitForSleepers(1, limit: .seconds(30))
        sleeping.cancel()
        #expect(await sleeping.value)
        #expect(clock.sleeperCount == 0)
    }
}
