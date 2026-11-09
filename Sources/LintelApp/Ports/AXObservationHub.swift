import AppKit
import ApplicationServices
import Foundation
import LintelKit
import Synchronization
import os

/// Observes the windows of every regular app through `AXObserver` (spec: Architecture, "AXWindowClient"). One
/// dedicated thread runs a run loop; every observer's source lives on it, and the callbacks only append to the
/// `AXEventBuffer`, so nothing here blocks the main thread or the engine.
///
/// Everything on the AX thread follows the no-trap rule: every Accessibility call is checked, a failure skips
/// that app or window. A hung app costs at most the 0.25 s messaging timeout on its own element. Window titles and
/// bundle ids are never logged. Real Accessibility cannot be exercised in unit tests; the pure parts
/// (`AXEventBuffer`, `AXNotificationMapper`, `AppObservationPlan`) are, and the rest is a manual item in
/// `docs/qa.md`.
nonisolated final class AXObservationHub: @unchecked Sendable {
    static let messagingTimeout: Float = 0.25

    /// Per observed app. Owned by the AX thread; its address is the observer's `refcon`.
    private final class AppState {
        let pid: Int32
        let application: AXUIElement
        weak var hub: AXObservationHub?
        var observer: AXObserver?
        /// Window numbers of the elements this app's observer registered, kept because a destroyed element can no
        /// longer be asked for its number.
        var numbers: [AXUIElement: UInt32] = [:]

        init(pid: Int32, application: AXUIElement, hub: AXObservationHub) {
            self.pid = pid
            self.application = application
            self.hub = hub
        }
    }

    private let buffer: AXEventBuffer
    private let lookup: WindowIDLookup
    private let ownPID: Int32
    private let terminated: @Sendable (Int32) -> Void
    private let logger = Logger(subsystem: "com.lintelapp", category: "windows")
    /// `start`, `stop` and the notification handlers run on different threads: this state is behind one lock.
    private struct Shared: @unchecked Sendable {
        var thread: Thread?
        var runLoop: CFRunLoop?
        var tokens: [any NSObjectProtocol] = []
        var isStopped = false
    }

    private let shared = Mutex(Shared())
    private var runLoop: CFRunLoop? { shared.withLock { $0.runLoop } }
    /// AX thread only.
    private var apps: [Int32: AppState] = [:]

    init(
        buffer: AXEventBuffer, lookup: WindowIDLookup, ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        terminated: @escaping @Sendable (Int32) -> Void = { _ in }
    ) {
        self.terminated = terminated
        self.buffer = buffer
        self.lookup = lookup
        self.ownPID = ownPID
    }

    // MARK: Lifecycle

    /// Starts the thread and observes every regular app. Safe to call more than once; a `stop()` that came first
    /// wins. The thread reports its run loop through a continuation, so nothing waits on a thread-blocking
    /// primitive on the cooperative pool.
    func start() async {
        let alreadyRunning = shared.withLock { shared -> Bool in
            if shared.isStopped || shared.thread != nil { return true }
            return false
        }
        guard !alreadyRunning else { return }
        let runLoop = await withCheckedContinuation { (continuation: CheckedContinuation<CFRunLoop, Never>) in
            let thread = Thread {
                let current = CFRunLoopGetCurrent()
                // A source with no work keeps the run loop alive.
                var context = CFRunLoopSourceContext()
                let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)
                CFRunLoopAddSource(current, keepAlive, .defaultMode)
                if let current { continuation.resume(returning: current) }
                CFRunLoopRun()
            }
            thread.name = "com.lintelapp.windows.ax"
            thread.qualityOfService = .userInitiated
            shared.withLock { $0.thread = thread }
            thread.start()
        }
        let stopped = shared.withLock { shared -> Bool in
            shared.runLoop = runLoop
            return shared.isStopped
        }
        if stopped {
            CFRunLoopStop(runLoop)
            return
        }
        observeSystemNotifications()
        // `NSWorkspace.runningApplications` is read on the main actor.
        let wanted = await MainActor.run { () -> Set<Int32> in
            let running = NSWorkspace.shared.runningApplications.map {
                AppObservationPlan.App(
                    pid: $0.processIdentifier, isRegular: $0.activationPolicy == .regular,
                    isTerminated: $0.isTerminated)
            }
            return AppObservationPlan.pids(for: running, ownPID: ProcessInfo.processInfo.processIdentifier)
        }
        let ownPID = ownPID
        perform { [self] in for pid in wanted.sorted() where pid != ownPID { observe(pid) } }
    }

    func stop() {
        let tokens = shared.withLock { shared -> [any NSObjectProtocol] in
            shared.isStopped = true
            let tokens = shared.tokens
            shared.tokens = []
            shared.thread = nil
            return tokens
        }
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        perform { [self] in
            for pid in Array(apps.keys) { unobserve(pid) }
            if let loop = runLoop { CFRunLoopStop(loop) }
        }
    }

    /// Runs `work` on the AX thread.
    private func perform(_ work: @escaping @Sendable () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    /// Keeps a system notification token; one that arrives after `stop()` is removed at once.
    private func add(_ token: any NSObjectProtocol) {
        let stopped = shared.withLock { shared -> Bool in
            if shared.isStopped { return true }
            shared.tokens.append(token)
            return false
        }
        if stopped { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    private func observeSystemNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        let buffer = buffer
        let ownPID = ownPID
        add(
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) {
                [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.activationPolicy == .regular, app.processIdentifier != ownPID
                else { return }
                let pid = app.processIdentifier
                buffer.append(.appLaunched(pid: pid))
                guard let self else { return }
                self.perform { [self] in observe(pid) }
            })
        add(
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) {
                [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                let pid = app.processIdentifier
                buffer.append(.appTerminated(pid: pid))
                guard let self else { return }
                self.terminated(pid)
                self.perform { [self] in unobserve(pid) }
            })
        add(
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { _ in
                buffer.append(.spaceChanged)
            })
        add(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
            ) { _ in buffer.append(.displaysChanged) })
    }

    // MARK: Observers (AX thread only)

    private func observe(_ pid: Int32) {
        guard apps[pid] == nil, pid != ownPID, let runLoop else { return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        let state = AppState(pid: pid, application: application, hub: self)
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let state = Unmanaged<AXObservationHub.AppState>.fromOpaque(refcon).takeUnretainedValue()
            AXObservationHub.handle(state: state, element: element, notification: notification as String)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        state.observer = observer
        apps[pid] = state
        let refcon = Unmanaged.passUnretained(state).toOpaque()
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        addAppNotifications(state, attempt: 0)
        registerExistingWindows(of: state)
    }

    /// An app that is not ready yet refuses its notifications: they are tried again after 1, 2 and 4 seconds (the
    /// engine's snapshot still sees its windows meanwhile). Needs a real app to observe, so it is a manual item.
    private func addAppNotifications(_ state: AppState, attempt: Int) {
        guard let observer = state.observer else { return }
        let refcon = Unmanaged.passUnretained(state).toOpaque()
        var failed = false
        for name in AXNotificationMapper.appNotifications {
            let result = AXObserverAddNotification(observer, state.application, name as CFString, refcon)
            if result != .success, result != .notificationAlreadyRegistered { failed = true }
        }
        guard failed, attempt < 3 else { return }
        let pid = state.pid
        let delay = Double(1 << attempt)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.perform { [weak self] in
                guard let self, let current = apps[pid], current === state else { return }
                addAppNotifications(current, attempt: attempt + 1)
            }
        }
    }

    /// Stops observing an app. The `AppState` is passed to Accessibility as an unretained `refcon`, which is safe
    /// by one invariant: callbacks run only on this thread's run loop, and `unobserve` runs on the same thread,
    /// so no callback can be in flight while it runs. The local `state` keeps the object alive until the source
    /// is removed, after which no callback can name it any more.
    private func unobserve(_ pid: Int32) {
        guard let state = apps.removeValue(forKey: pid), let observer = state.observer, let runLoop else { return }
        CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        withExtendedLifetime(state) {}
    }

    private func registerExistingWindows(of state: AppState) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(state.application, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else { return }
        for window in windows {
            guard let number = register(window, in: state) else { continue }
            buffer.append(.created(WindowID(pid: state.pid, number: number)))
        }
    }

    /// Observes one window's own notifications and remembers its number.
    @discardableResult
    private func register(_ window: AXUIElement, in state: AppState) -> UInt32? {
        if let known = state.numbers[window] { return known }
        guard let observer = state.observer, let number = lookup.windowID(of: window) else { return nil }
        AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
        state.numbers[window] = number
        let refcon = Unmanaged.passUnretained(state).toOpaque()
        for name in AXNotificationMapper.windowNotifications {
            _ = AXObserverAddNotification(observer, window, name as CFString, refcon)
        }
        return number
    }

    /// The callback, on the AX thread.
    private static func handle(state: AppState, element: AXUIElement, notification: String) {
        guard let hub = state.hub else { return }
        hub.process(state: state, element: element, notification: notification)
    }

    private func process(state: AppState, element: AXUIElement, notification: String) {
        var number: UInt32?
        switch notification {
        case kAXWindowCreatedNotification:
            number = register(element, in: state)
        case kAXFocusedWindowChangedNotification:
            number = register(element, in: state) ?? lookup.windowID(of: element)
        case kAXUIElementDestroyedNotification:
            // A destroyed element cannot be asked any more: the remembered number is the only answer.
            number = state.numbers.removeValue(forKey: element)
        default:
            number = state.numbers[element] ?? lookup.windowID(of: element)
        }
        if let event = AXNotificationMapper.event(for: notification, pid: state.pid, windowNumber: number) {
            buffer.append(event)
        }
    }
}
