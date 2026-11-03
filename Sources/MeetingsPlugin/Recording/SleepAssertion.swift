import Foundation
import IOKit.pwr_mgt
import Synchronization

/// Keeps the Mac awake while a meeting is recorded (spec: Edge Cases, "Uśpienie Maca"). Internal to the plugin
/// and injected into `MeetingSession`; tests use a recording fake, so no real assertion is ever taken.
protocol SleepAssertion: Sendable {
    /// Starts preventing idle sleep. Calling it again while held does nothing.
    func hold(reason: String)
    /// Gives the assertion back. Calling it when nothing is held does nothing.
    func release()
}

/// `IOPMAssertionCreateWithName` with `kIOPMAssertionTypePreventUserIdleSystemSleep`: the display may sleep,
/// the system does not. Compiled but not exercised by tests.
final class IOKitSleepAssertion: SleepAssertion {
    private let identifier = Mutex<IOPMAssertionID?>(nil)

    func hold(reason: String) {
        identifier.withLock { identifier in
            guard identifier == nil else { return }
            var created = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &created)
            if result == kIOReturnSuccess { identifier = created }
        }
    }

    func release() {
        identifier.withLock { identifier in
            guard let current = identifier else { return }
            IOPMAssertionRelease(current)
            identifier = nil
        }
    }

    deinit {
        if let current = identifier.withLock({ $0 }) { IOPMAssertionRelease(current) }
    }
}

/// At most one recording at a time (spec: `MeetingSession`). One gate is shared by everything that can start a
/// session; a second `tryAcquire()` fails until the first holder calls `release()`.
final class MeetingSessionGate: Sendable {
    private let taken = Mutex(false)

    func tryAcquire() -> Bool {
        taken.withLock { taken in
            guard !taken else { return false }
            taken = true
            return true
        }
    }

    func release() {
        taken.withLock { $0 = false }
    }

    var isTaken: Bool { taken.withLock { $0 } }
}
