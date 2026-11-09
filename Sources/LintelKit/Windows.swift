import CoreGraphics
import Foundation

// The window port (spec `2026-11-09-window-management`, step 1.2). Everything here is additive: a new port,
// its value types, `PluginContext.windows` and `LintelPlugin.recoverAtLaunch`, each with a default.

/// A window of another application: its process and its window number. It is valid only while that window
/// exists (pids and window numbers are reused after a reboot), so anything stored for later also keeps the
/// process start time (`WindowClient.processStart(of:)`).
public struct WindowID: Hashable, Sendable, Codable, Comparable {
    public let pid: Int32
    public let number: UInt32

    public init(pid: Int32, number: UInt32) {
        self.pid = pid
        self.number = number
    }

    public static func < (lhs: WindowID, rhs: WindowID) -> Bool {
        (lhs.pid, lhs.number) < (rhs.pid, rhs.number)
    }
}

/// What the plugin may know about a window. The title lives in memory only: it is never logged, stored or
/// recorded.
public struct WindowInfo: Hashable, Sendable {
    public let id: WindowID
    public let bundleID: String?
    public let title: String
    /// In the global coordinate space of the Accessibility API (origin at the top left of the main display).
    public let frame: CGRect
    /// A standard window (`AXStandardWindow`) as opposed to a dialog, sheet, panel or floating window.
    public let isStandard: Bool
    public let isMinimized: Bool
    public let isFullscreen: Bool

    public init(
        id: WindowID,
        bundleID: String? = nil,
        title: String = "",
        frame: CGRect,
        isStandard: Bool = true,
        isMinimized: Bool = false,
        isFullscreen: Bool = false
    ) {
        self.id = id
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.isStandard = isStandard
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
    }
}

public enum DisplayOrientation: String, Hashable, Sendable, Codable {
    case landscape
    case portrait
}

/// One connected display.
public struct DisplayInfo: Hashable, Sendable {
    /// `CGDirectDisplayID`; changes when displays are re-plugged.
    public let id: UInt32
    /// `CGDisplayCreateUUIDFromDisplayID`: stable across reconnects, the key of anything stored per display.
    public let uuid: String
    /// The whole display, in the same coordinate space as `WindowInfo.frame`.
    public let frame: CGRect
    /// The part windows may use (menu bar and Dock excluded).
    public let visibleFrame: CGRect
    public let isMain: Bool

    public init(id: UInt32, uuid: String, frame: CGRect, visibleFrame: CGRect? = nil, isMain: Bool = false) {
        self.id = id
        self.uuid = uuid
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
        self.isMain = isMain
    }

    public var orientation: DisplayOrientation { frame.height > frame.width ? .portrait : .landscape }
}

/// A change in the windows or displays, delivered by `WindowClient.events`.
public enum WindowEvent: Hashable, Sendable {
    case created(WindowID)
    case destroyed(WindowID)
    case moved(WindowID)
    case resized(WindowID)
    /// The focused window changed; `nil` when no window has focus.
    case focused(WindowID?)
    case appLaunched(pid: Int32)
    case appTerminated(pid: Int32)
    case displaysChanged
    case spaceChanged
}

/// Whether the client can work on this Mac.
public enum WindowClientAvailability: Hashable, Sendable {
    case available
    /// A required system facility is missing (for example the private window-id symbol); the reason is a
    /// short English diagnostic, never a window title or bundle id.
    case unsupported(reason: String)
}

public enum WindowClientError: Error, Hashable, Sendable {
    /// Accessibility is not trusted.
    case notTrusted
    /// The window no longer exists.
    case windowGone
    /// The app did not answer within its messaging timeout.
    case timedOut
    /// The app refused the change.
    case refused
}

/// Reads and moves the windows of other applications through the Accessibility API. The shell provides the
/// real implementation (`AXWindowClient`); tests provide an in-memory one. The default reports no windows and
/// no displays and is `unsupported`.
public protocol WindowClient: Sendable {
    /// Read by `activate()`, which throws on `.unsupported` so the host marks the plugin `failed`.
    var availability: WindowClientAvailability { get }
    /// `availability`, read where blocking is allowed: a real client may call Accessibility for its self-check,
    /// so an async caller uses this and never reads the property on the main actor or the cooperative pool. The
    /// default answers `availability`.
    func checkAvailability() async -> WindowClientAvailability
    /// Whether the app answers Accessibility requests within its messaging timeout. A window that is missing from
    /// `windows()` is on another Space when its app answers, and not reachable when it does not. The default
    /// answers `true`.
    func isResponding(pid: Int32) async -> Bool
    /// Every window of the current native Space, minimised and fullscreen ones included (flagged).
    func windows() async -> [WindowInfo]
    func focusedWindow() async -> WindowID?
    /// One window, read on its own: what an event about it needs, without scanning every app. `nil` when the
    /// window is gone. The default filters `windows()`; a real client reads only that window.
    func window(id: WindowID) async -> WindowInfo?
    /// Sets the frame and returns the frame the window ended up with (read back), so a caller can tell that a
    /// window refused a size.
    @discardableResult
    func setFrame(_ frame: CGRect, for id: WindowID) async throws(WindowClientError) -> CGRect
    func focus(_ id: WindowID) async throws(WindowClientError)
    func displays() async -> [DisplayInfo]
    /// A bounded, coalesced stream: the newest events win when the consumer is slow.
    var events: AsyncStream<WindowEvent> { get }
    /// When the process started, as seconds since 1970; `nil` when the process is gone or unknown. A stored
    /// window id is trusted only while its process start time still matches.
    func processStart(of pid: Int32) -> TimeInterval?
}

extension WindowClient {
    public func checkAvailability() async -> WindowClientAvailability { availability }
    public func isResponding(pid: Int32) async -> Bool { true }
    public func window(id: WindowID) async -> WindowInfo? { await windows().first { $0.id == id } }
    public func processStart(of pid: Int32) -> TimeInterval? { nil }
}

/// The default client: no windows, no displays, unsupported.
public struct NoWindowClient: WindowClient {
    public init() {}

    public var availability: WindowClientAvailability { .unsupported(reason: "No window client") }
    public func windows() async -> [WindowInfo] { [] }
    public func focusedWindow() async -> WindowID? { nil }

    public func setFrame(_ frame: CGRect, for id: WindowID) async throws(WindowClientError) -> CGRect {
        throw .windowGone
    }

    public func focus(_ id: WindowID) async throws(WindowClientError) {
        throw .windowGone
    }

    public func displays() async -> [DisplayInfo] { [] }
    public var events: AsyncStream<WindowEvent> { AsyncStream { $0.finish() } }
}

/// What `LintelPlugin.recoverAtLaunch` achieved.
public enum RecoveryOutcome: Hashable, Sendable {
    /// Nothing was left to do, or everything was done.
    case done
    /// It could not run yet (a missing permission) or did not finish in time; the plugin keeps what is left
    /// and the host tries again on app activation and on a permission change.
    case deferred
}
