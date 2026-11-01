import Foundation
import PounceKit
import os

/// What one capture read from the pasteboard, handed to the background for classification and storage.
struct Capture: Sendable {
    let contents: PasteboardContents
    let source: RunningApplication?
    let capturedAt: Date
}

/// Watches the pasteboard: every 0.5 s on the main actor it compares `changeCount`; on a change it
/// checks the pasteboard access setting, the marker types and the source app, copies the contents (on
/// the main actor, ADR 0002), compares `changeCount` again and hands the copy to `onCapture`, which
/// classifies, hashes and stores it in the background.
///
/// - Access: `accessBehavior` is read on every change, before any type or data, and reported through
///   `onAccess`. Under `.ask` or `.alwaysDeny` nothing is read (reading would prompt or fail), but the
///   watcher keeps comparing `changeCount`, which never prompts, so allowing access again resumes
///   recording on the next copy (spec: Edge Cases, "Watcher wykrywa `accessBehavior`").
/// - Source app: the frontmost app is noted on every tick. A change is skipped when the app frontmost
///   now **or** at the previous tick is ignored, so copying a password and switching apps within the
///   0.5 s poll interval is not recorded under the next app.
///
/// The plugin stops the watcher when the plugin is disabled, recording is paused or the history is
/// unavailable, so a stopped watcher never touches the pasteboard.
@MainActor
final class PasteboardWatcher {
    static let interval: Duration = .milliseconds(500)

    enum Event: Equatable {
        case captured
        case skipped(CaptureFilter.Skip)
        /// The pasteboard changed again while it was read; the newer state is handled next.
        case changedDuringRead
        case ownWrite
    }

    private let pasteboard: any PasteboardClient
    private let workspace: any WorkspaceClient
    private let clock: any Clock<Duration>
    private let now: () -> Date
    private let logger: Logger
    private let filter: () -> CaptureFilter
    private let onAccess: (PasteboardAccess) -> Void
    private let onCapture: (Capture) -> Void
    private var task: Task<Void, Never>?
    private var lastChangeCount: Int?
    /// The app that was frontmost at the previous tick.
    private var lastFrontmost: RunningApplication?
    private var ownChangeCounts: Set<Int> = []

    /// The last thing a check did (tests and logs).
    private(set) var lastEvent: Event?

    init(
        pasteboard: any PasteboardClient,
        workspace: any WorkspaceClient,
        clock: any Clock<Duration>,
        now: @escaping () -> Date = { Date() },
        logger: Logger,
        filter: @escaping () -> CaptureFilter,
        onAccess: @escaping (PasteboardAccess) -> Void = { _ in },
        onCapture: @escaping (Capture) -> Void
    ) {
        self.pasteboard = pasteboard
        self.workspace = workspace
        self.clock = clock
        self.now = now
        self.logger = logger
        self.filter = filter
        self.onAccess = onAccess
        self.onCapture = onCapture
    }

    var isRunning: Bool { task != nil }

    /// Starts polling. What is on the pasteboard already is not captured; only later changes are.
    func start() {
        guard task == nil else { return }
        lastChangeCount = pasteboard.changeCount
        lastFrontmost = workspace.frontmostApplication
        let clock = clock
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Self.interval)
                } catch {
                    return
                }
                self?.check()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Pounce wrote this `changeCount` itself (pasting from the history), so it is not recorded again.
    func ignore(changeCount: Int) {
        ownChangeCounts.insert(changeCount)
        if ownChangeCounts.count > 16 {
            ownChangeCounts.remove(ownChangeCounts.min() ?? changeCount)
        }
    }

    /// One poll. Returns whether anything changed.
    @discardableResult
    func check() -> Bool {
        let source = workspace.frontmostApplication
        let previousSource = lastFrontmost
        lastFrontmost = source
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return false }
        lastChangeCount = changeCount
        if ownChangeCounts.remove(changeCount) != nil {
            lastEvent = .ownWrite
            return true
        }
        let access = pasteboard.accessBehavior
        onAccess(access)
        guard access.allowsRecording else {
            record(.skipped(.accessNotAllowed))
            return true
        }
        let filter = filter()
        let sources = [source?.bundleIdentifier, previousSource?.bundleIdentifier].compactMap { $0 }
        if let skip = filter.skipBeforeReading(types: pasteboard.types(), sourceBundleIDs: sources) {
            record(.skipped(skip))
            return true
        }
        guard let contents = pasteboard.readContents(maxBytes: filter.maximumBytes, including: ClipClassifier.keeps)
        else {
            record(.skipped(.empty))
            return true
        }
        guard pasteboard.changeCount == changeCount else {
            // Forget the count so the next poll reads the newer contents.
            lastChangeCount = nil
            lastEvent = .changedDuringRead
            return true
        }
        if let skip = filter.skipAfterReading(contents) {
            record(.skipped(skip))
            return true
        }
        lastEvent = .captured
        onCapture(Capture(contents: contents, source: source, capturedAt: now()))
        return true
    }

    private func record(_ event: Event) {
        lastEvent = event
        if case .skipped(let reason) = event {
            logger.debug("Skipped a pasteboard change: \(String(describing: reason), privacy: .public)")
        }
    }
}
