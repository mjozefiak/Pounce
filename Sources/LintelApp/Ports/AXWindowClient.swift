import AppKit
import ApplicationServices
import Foundation
import LintelKit
import Synchronization
import os

/// The real `WindowClient`: reads and moves the windows of other apps through the Accessibility API (spec:
/// Architecture, "AXWindowClient"). It follows the same no-trap rule as plugin code, because a crash here takes
/// the whole app down: every call is checked, a failure becomes a `WindowClientError`, and nothing is
/// force-unwrapped.
///
/// - Availability: the private window id function and its start-up self-check (`WindowIDGuard`).
/// - Reads and writes for one app run on that app's serial queue (`PerProcessQueues`), apps in parallel.
/// - `events` starts the observation thread on first use and stops it when the consumer goes away
///   (`AXObservationHub`), so a plugin that is off costs nothing.
/// - Window titles live in memory only and are never logged.
///
/// Real Accessibility cannot be exercised in unit tests (`docs/qa.md` lists what to check by hand). The cross-
/// display order (size, position, size) and the messaging timeout are assumptions of ADR 0009 that stay single
/// constants until the spike measures them.
nonisolated final class AXWindowClient: WindowClient, Sendable {
    static let messagingTimeout: Float = 0.25

    private struct StreamState {
        var stream: AsyncStream<WindowEvent>?
        var hub: AXObservationHub?
    }

    /// Cached `AXUIElement` of each window. `@unchecked Sendable` rests on one invariant: an instance is touched
    /// only on its owner's serial queue (`PerProcessQueues`), never from two threads; the lock-protected `caches`
    /// dictionary only hands out the reference.
    private final class ElementCache: @unchecked Sendable {
        var elements: [WindowID: AXUIElement] = [:]
    }

    private let guardian: WindowIDGuard
    private let lookup: WindowIDLookup
    private let queues: PerProcessQueues
    private let streamState = Mutex(StreamState())
    private let caches = Mutex<[Int32: ElementCache]>([:])
    private let logger = Logger(subsystem: "com.lintelapp", category: "windows")

    init(
        lookup: WindowIDLookup = .live, sampler: any WindowIDSampling = SystemWindowIDSampler(),
        queues: PerProcessQueues = PerProcessQueues()
    ) {
        self.lookup = lookup
        self.guardian = WindowIDGuard(lookup: lookup, sampler: sampler)
        self.queues = queues
    }

    var availability: WindowClientAvailability { guardian.availability }

    /// The self-check can call Accessibility, which can block: it runs on a global queue, never on the caller's
    /// executor.
    func checkAvailability() async -> WindowClientAvailability {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [guardian] in
                continuation.resume(returning: guardian.availability)
            }
        }
    }

    func processStart(of pid: Int32) -> TimeInterval? { ProcessStart.read(pid: pid) }

    // MARK: Events

    /// Starts observing every regular app and returns the stream. One subscriber at a time: a second call while
    /// the first stream lives returns that stream. The observation thread stops when the stream ends, so a plugin
    /// that is off costs nothing.
    func subscribe() async -> AsyncStream<WindowEvent> {
        let (stream, hub, isNew) = streamState.withLock {
            state -> (AsyncStream<WindowEvent>, AXObservationHub?, Bool) in
            if let stream = state.stream { return (stream, nil, false) }
            let (stream, buffer) = AXEventBuffer.make()
            let hub = AXObservationHub(
                buffer: buffer, lookup: lookup, terminated: { [weak self] pid in self?.forget(pid: pid) })
            buffer.onTermination { [weak self] in
                // The engine stopped listening: stop observing, and let the next subscription start afresh.
                hub.stop()
                // Only this subscription's own state: a newer subscription may already have taken its place.
                self?.streamState.withLock {
                    guard $0.hub === hub else { return }
                    $0.stream = nil
                    $0.hub = nil
                }
            }
            state.stream = stream
            state.hub = hub
            return (stream, hub, true)
        }
        if isNew { await hub?.start() }
        return stream
    }

    /// An app quit: its serial queue and its element cache are dropped.
    func forget(pid: Int32) {
        queues.forget(pid: pid)
        caches.withLock { _ = $0.removeValue(forKey: pid) }
    }

    var cachedProcessCount: Int { caches.withLock { $0.count } }

    // MARK: Reading

    func windows() async -> [WindowInfo] {
        guard AXIsProcessTrusted() else { return [] }
        let apps = await Self.regularApps()
        return await withTaskGroup(of: [WindowInfo].self) { group in
            for app in apps {
                group.addTask { [self] in
                    await queues.run(pid: app.pid) { [self] in readWindows(of: app) }
                }
            }
            var all: [WindowInfo] = []
            for await part in group { all.append(contentsOf: part) }
            return all.sorted { $0.id < $1.id }
        }
    }

    func window(id: WindowID) async -> WindowInfo? {
        guard AXIsProcessTrusted() else { return nil }
        let bundleID = await Self.bundleID(of: id.pid)
        return await queues.run(pid: id.pid) { [self] in
            guard case .found(let element) = self.element(for: id) else { return nil }
            return Self.info(of: element, id: id, bundleID: bundleID)
        }
    }

    func isResponding(pid: Int32) async -> Bool {
        guard AXIsProcessTrusted() else { return true }
        return await queues.run(pid: pid) {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(application, kAXRoleAttribute as CFString, &value) != .cannotComplete
        }
    }

    func focusedWindow() async -> WindowID? {
        guard AXIsProcessTrusted(), let app = await Self.frontmostApp() else { return nil }
        return await queues.run(pid: app.pid) { [self] in
            let application = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
                let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
                let number = lookup.windowID(of: unsafeDowncast(value, to: AXUIElement.self))
            else { return nil }
            return WindowID(pid: app.pid, number: number)
        }
    }

    func displays() async -> [DisplayInfo] {
        await MainActor.run { WindowGeometry.displays() }
    }

    // MARK: Writing

    func setFrame(_ frame: CGRect, for id: WindowID) async throws(WindowClientError) -> CGRect {
        guard AXIsProcessTrusted() else { throw .notTrusted }
        let result = await queues.run(pid: id.pid) { [self] () -> Result<CGRect, WindowClientError> in
            let element: AXUIElement
            switch self.element(for: id) {
            case .found(let found): element = found
            case .gone: return .failure(.windowGone)
            // An app that does not answer is not a window that is gone: the engine keeps the window and retries.
            case .unreachable: return .failure(.timedOut)
            }
            // Size, position, size: a window that crosses to a display with another scale takes the last size
            // (ADR 0009 row 5, unmeasured; one place to change).
            var failure: WindowClientError?
            for step in [Step.size, .position, .size] {
                if let error = write(step, frame, to: element) {
                    failure = error
                    if error == .windowGone || error == .timedOut || error == .notTrusted { break }
                }
            }
            if let failure, failure != .refused { return .failure(failure) }
            guard let actual = SystemWindowIDSampler.frame(of: element) else {
                return .failure(failure ?? .refused)
            }
            return .success(actual)
        }
        switch result {
        case .success(let actual): return actual
        case .failure(let error): throw error
        }
    }

    func focus(_ id: WindowID) async throws(WindowClientError) {
        guard AXIsProcessTrusted() else { throw .notTrusted }
        let result = await queues.run(pid: id.pid) { [self] () -> WindowClientError? in
            let element: AXUIElement
            switch self.element(for: id) {
            case .found(let found): element = found
            case .gone: return .windowGone
            case .unreachable: return .timedOut
            }
            let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            return WindowGeometry.clientError(for: raised)
        }
        await MainActor.run {
            _ = NSRunningApplication(processIdentifier: id.pid)?.activate()
        }
        if let result { throw result }
    }

    // MARK: Elements (on the process's queue)

    private enum Step { case size, position }

    private func write(_ step: Step, _ frame: CGRect, to element: AXUIElement) -> WindowClientError? {
        var size = frame.size
        var origin = frame.origin
        let value: AXValue?
        let attribute: String
        switch step {
        case .size:
            value = AXValueCreate(.cgSize, &size)
            attribute = kAXSizeAttribute
        case .position:
            value = AXValueCreate(.cgPoint, &origin)
            attribute = kAXPositionAttribute
        }
        guard let value else { return .refused }
        return WindowGeometry.clientError(for: AXUIElementSetAttributeValue(element, attribute as CFString, value))
    }

    private func cache(for pid: Int32) -> ElementCache {
        caches.withLock { caches in
            if let existing = caches[pid] { return existing }
            let created = ElementCache()
            caches[pid] = created
            return created
        }
    }

    /// The element of a window: the remembered one while it still answers with the same number, else found again
    /// in the app's window list.
    /// What looking for a window's element found. `unreachable` is an app that did not answer within the messaging
    /// timeout (hung, stopped): the window is not known to be gone, so callers must not report it as gone.
    private enum ElementLookup {
        case found(AXUIElement)
        case gone
        case unreachable
    }

    private func element(for id: WindowID) -> ElementLookup {
        let cache = cache(for: id.pid)
        if let known = cache.elements[id], lookup.windowID(of: known) == id.number { return .found(known) }
        let application = AXUIElementCreateApplication(id.pid)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        // The cached element stays while the app does not answer: it may be good again when it does.
        if status == .cannotComplete { return .unreachable }
        cache.elements[id] = nil
        guard status == .success, let windows = value as? [AXUIElement] else { return .gone }
        for window in windows {
            guard let number = lookup.windowID(of: window) else { continue }
            AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
            cache.elements[WindowID(pid: id.pid, number: number)] = window
        }
        return cache.elements[id].map { .found($0) } ?? .gone
    }

    private func readWindows(of app: RunningApp) -> [WindowInfo] {
        let application = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else { return [] }
        let cache = cache(for: app.pid)
        var infos: [WindowInfo] = []
        var seen: [WindowID: AXUIElement] = [:]
        for window in windows {
            guard let number = lookup.windowID(of: window) else { continue }
            AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
            let id = WindowID(pid: app.pid, number: number)
            guard let info = Self.info(of: window, id: id, bundleID: app.bundleID) else { continue }
            seen[id] = window
            infos.append(info)
        }
        cache.elements = seen
        return infos
    }

    private static func info(of window: AXUIElement, id: WindowID, bundleID: String?) -> WindowInfo? {
        guard let frame = SystemWindowIDSampler.frame(of: window) else { return nil }
        return WindowInfo(
            id: id, bundleID: bundleID, title: string(window, kAXTitleAttribute) ?? "", frame: frame,
            isStandard: string(window, kAXRoleAttribute) == kAXWindowRole
                && string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
            isMinimized: bool(window, kAXMinimizedAttribute), isFullscreen: bool(window, "AXFullScreen"))
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    // MARK: Applications (main actor)

    struct RunningApp: Sendable {
        var pid: Int32
        var bundleID: String?
    }

    @MainActor private static func regularApps() -> [RunningApp] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != own }
            .map { RunningApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier) }
    }

    @MainActor private static func bundleID(of pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    @MainActor private static func frontmostApp() -> RunningApp? {
        guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated else { return nil }
        return RunningApp(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
    }
}
