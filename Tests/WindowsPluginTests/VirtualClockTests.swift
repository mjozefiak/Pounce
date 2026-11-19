import Synchronization
import Testing

@testable import WindowsPlugin

/// The test clock is shared by most engine tests, so a sleeper it leaks makes `sleeperCount` assertions flaky (#101).
@Suite(.timeLimit(.minutes(1))) struct VirtualClockTests {
    @Test func aSleepCancelledBeforeItIsRegisteredLeavesNoSleeperBehind() async {
        let clock = VirtualClock(autoAdvance: false)
        // Cancel the sleeping task itself after its first cancellation check and before it registers: the window a
        // cancel hits on a loaded machine.
        clock.beforeRegistration = { withUnsafeCurrentTask { $0?.cancel() } }
        let outcome = Mutex<Bool?>(nil)
        let sleeping = Task {
            do {
                try await clock.sleep(until: clock.now.advanced(by: .seconds(60)), tolerance: nil)
                outcome.withLock { $0 = false }
            } catch is CancellationError {
                outcome.withLock { $0 = true }
            } catch {
                outcome.withLock { $0 = false }
            }
        }
        // A sleeper left behind never ends: the wait is bounded so that fails the test instead of hanging it.
        let ended = await waitForState("the cancelled sleep ended", { outcome.withLock { $0 != nil } })
        sleeping.cancel()
        #expect(ended)
        #expect(outcome.withLock { $0 } == true)
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
