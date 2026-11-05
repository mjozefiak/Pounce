import Foundation
import LintelKit
import Synchronization

@testable import AppsPlugin

/// Virtual time shared by a `VirtualClock` and the `now` closures: sleeping advances it at once, so
/// minutes of tracking run in microseconds and every check sees an exact time.
final class VirtualTime: Sendable {
    private let seconds: Mutex<TimeInterval>
    let origin: Date

    init(origin: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.origin = origin
        self.seconds = Mutex(0)
    }

    /// Seconds since `origin`.
    var elapsed: TimeInterval { seconds.withLock { $0 } }
    var date: Date { origin.addingTimeInterval(elapsed) }
    var now: @Sendable () -> Date { { [self] in date } }

    func advance(to target: TimeInterval) {
        seconds.withLock { $0 = max($0, target) }
    }

    func advance(by delta: TimeInterval) {
        seconds.withLock { $0 += delta }
    }
}

struct VirtualClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    let time: VirtualTime

    var now: Instant { Instant(offset: .milliseconds(Int64((time.elapsed * 1000).rounded()))) }
    var minimumResolution: Duration { .milliseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let components = deadline.offset.components
        time.advance(to: Double(components.seconds) + Double(components.attoseconds) / 1e18)
        await Task.yield()
        try Task.checkCancellation()
    }
}

/// A clock whose sleeps only end by cancellation.
struct NeverClock: Clock {
    var now: ContinuousClock.Instant { ContinuousClock().now }
    var minimumResolution: Duration { .milliseconds(1) }

    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
        try await Task.sleep(for: .seconds(3600 * 24))
    }
}

/// A temporary directory, removed by `remove()`.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "lintel-activity-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A workspace whose frontmost app, idle time and running apps follow a script over virtual time.
@MainActor
final class ScriptedWorkspace: WorkspaceClient {
    let time: VirtualTime
    /// The frontmost bundle identifier at a virtual time (seconds since the origin).
    var frontmost: (TimeInterval) -> String? = { _ in nil }
    /// Seconds since the last input at a virtual time.
    var idle: (TimeInterval) -> TimeInterval? = { _ in 0 }
    var running: Set<String> = []
    private let activations: AsyncStream<RunningApplication>
    let activationsContinuation: AsyncStream<RunningApplication>.Continuation
    private(set) var reveals: [[URL]] = []
    private(set) var opened: [URL] = []

    init(time: VirtualTime) {
        self.time = time
        (activations, activationsContinuation) = AsyncStream.makeStream()
    }

    nonisolated var frontmostApplicationPID: pid_t? { nil }

    func open(_ url: URL) async throws { opened.append(url) }

    func revealInFinder(_ urls: [URL]) { reveals.append(urls) }

    func openApplication(at url: URL, options: ApplicationOpenOptions) async throws { opened.append(url) }

    var frontmostApplication: RunningApplication? {
        frontmost(time.elapsed).map { RunningApplication(processIdentifier: 1, bundleIdentifier: $0) }
    }

    nonisolated func applicationActivations() -> AsyncStream<RunningApplication> { activations }

    var runningApplicationBundleIDs: Set<String> { running }

    var secondsSinceLastUserInput: TimeInterval? { idle(time.elapsed) }
}

/// Spotlight's used dates, by bundle path.
struct FakeUsageDatesReader: UsageDatesReader {
    let dates: [String: [Date]]

    func usedDates(of url: URL) -> [Date] {
        dates[url.path] ?? dates[url.path + "/"] ?? []
    }
}

/// Polls `condition` until it holds or about two seconds pass.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
