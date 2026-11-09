import Foundation
import LintelKit
import Synchronization

/// Whether Accessibility is trusted, readable from any thread. The engine's gate reads it before it moves a
/// window; the main actor writes it (`AccessibilityTrust`).
final class TrustFlag: Sendable {
    private let value = Mutex(false)

    var isTrusted: Bool { value.withLock { $0 } }

    /// Returns the previous value.
    @discardableResult
    func set(_ trusted: Bool) -> Bool {
        value.withLock { current in
            defer { current = trusted }
            return current
        }
    }
}

/// Tracks Accessibility for one running plugin: reads it when asked (a command, an app activation) and every
/// `pollInterval` while windows are parked, and reports a grant or a revoke once.
///
/// The state comes from `PermissionsReader`, a preflight read that never prompts.
@MainActor
final class AccessibilityTrust {
    static let defaultPollInterval: Duration = .seconds(2)

    let flag = TrustFlag()
    private let reader: any PermissionsReader
    private let clock: any Clock<Duration>
    private var known: Bool?
    private var poll: Task<Void, Never>?
    /// Called with the new value after Accessibility was granted or revoked; never for the first read.
    var onChange: @MainActor (Bool) -> Void = { _ in }

    private let pollInterval: Duration

    init(reader: any PermissionsReader, clock: any Clock<Duration>, pollInterval: Duration = defaultPollInterval) {
        self.reader = reader
        self.clock = clock
        self.pollInterval = pollInterval
    }

    var isTrusted: Bool { flag.isTrusted }

    /// Reads the permission now and returns it.
    @discardableResult
    func refresh() -> Bool {
        let trusted = reader.status(of: .accessibility) == .granted
        flag.set(trusted)
        if let known, known != trusted { onChange(trusted) }
        known = trusted
        return trusted
    }

    /// Reads the permission every `pollInterval` for as long as `isNeeded` says windows are parked.
    func startPolling(while isNeeded: @escaping @Sendable () async -> Bool) {
        poll?.cancel()
        let clock = clock
        let interval = pollInterval
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                await self?.pollOnce(while: isNeeded)
            }
        }
    }

    /// One poll: reads the permission when windows are parked. Counted, so a test can wait for it.
    func pollOnce(while isNeeded: @Sendable () async -> Bool) async {
        if await isNeeded() { refresh() }
        polls += 1
        let ready = pollWaiters.filter { $0.count <= polls }
        pollWaiters.removeAll { $0.count <= polls }
        for waiter in ready { waiter.continuation.resume() }
    }

    /// How many polls have finished.
    private(set) var polls = 0
    private var pollWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Waits until `count` polls have finished (tests).
    func waitForPolls(_ count: Int) async {
        if polls >= count { return }
        await withCheckedContinuation { pollWaiters.append((count, $0)) }
    }

    func stop() {
        poll?.cancel()
        poll = nil
    }
}
