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
    }

    private let shared = Mutex(Shared())
    private var thread: Thread? {
        get { shared.withLock { $0.thread } }
        set { shared.withLock { $0.thread = newValue } }
    }
    private var runLoop: CFRunLoop? {
        get { shared.withLock { $0.runLoop } }
        set { shared.withLock { $0.runLoop = newValue } }
    }
    private var tokens: [any NSObjectProtocol] {
        get { shared.withLock { $0.tokens } }
        set { shared.withLock { $0.tokens = newValue } }
    }
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

    /// Starts the thread and observes every regular app. Safe to call more than once.
    func start() {
        guard thread == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.runLoop = CFRunLoopGetCurrent()
            // A source with no work keeps the run loop alive.
            var context = CFRunLoopSourceContext()
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), keepAlive, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.lintelapp.windows.ax"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
        ready.wait()
        observeSystemNotifications()
        let running = NSWorkspace.shared.runningApplications.map {
            AppObservationPlan.App(
                pid: $0.processIdentifier, isRegular: $0.activationPolicy == .regular, isTerminated: $0.isTerminated)
        }
        let wanted = AppObservationPlan.pids(for: running, ownPID: ownPID)
        perform { [self] in for pid in wanted.sorted() { observe(pid) } }
    }

    func stop() {
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens = []
        perform { [self] in
            for pid in Array(apps.keys) { unobserve(pid) }
            if let runLoop { CFRunLoopStop(runLoop) }
        }
        thread = nil
    }

    /// Runs `work` on the AX thread.
    private func perform(_ work: @escaping @Sendable () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    private func observeSystemNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        let buffer = buffer
        let ownPID = ownPID
        tokens.append(
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
        tokens.append(
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
        tokens.append(
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { _ in
                buffer.append(.spaceChanged)
            })
        tokens.append(
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

    private func unobserve(_ pid: Int32) {
        guard let state = apps.removeValue(forKey: pid), let observer = state.observer, let runLoop else { return }
        CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
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
