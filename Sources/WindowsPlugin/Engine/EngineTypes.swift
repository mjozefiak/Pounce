import CoreGraphics
import Foundation
import LintelKit

// The value types of the window engine (spec: Architecture, "WindowEngine is a reducer plus effects"). The
// engine applies one pure function, `EngineReducer.reduce(state, input) -> (state, [EngineEffect])`, for every
// input; effects are executed afterwards by `WindowEngine` and never decide anything.

/// What the engine needs from the settings; a change arrives as an input.
struct EngineConfig: Equatable, Sendable {
    var followFocus = true
    /// Bundle identifiers of apps that are never arranged.
    var floatingBundleIDs: Set<String> = Set(WindowsSettings.defaultFloatingApps)
    /// A window that is re-hidden more than this many times is left alone until it is focused.
    var rehideCap = 3
    /// A move or resize event within this many points of a frame the engine set is our own echo.
    var echoTolerance: CGFloat = 2
    /// How long, in seconds, an expected frame suppresses echoes.
    var echoWindow: Double = 0.5
    /// How much of a parked window stays on its display. Unmeasured (ADR 0009, row 3); one place to change.
    var parkSliver: CGFloat = 1
}

/// A window the engine knows. The title is never kept.
struct TrackedWindow: Equatable, Sendable {
    var id: WindowID
    var bundleID: String?
    /// The frame as last seen; for a parked window the parked frame, otherwise the window's own.
    var frame: CGRect
    /// When the owning process started (seconds since 1970); a window without one is never parked, because it
    /// could not be journaled.
    var processStart: Double?
}

/// A window that is parked right now.
struct ParkRecord: Equatable, Sendable {
    var home: CGRect
    var parkedFrame: CGRect
    var processStart: Double
}

/// A frame the engine set, kept briefly to recognise its own echo.
struct ExpectedFrame: Equatable, Sendable {
    var frame: CGRect
    var expires: Double
}

/// Counters for *Copy diagnostics*: counts only, no titles and no bundle ids.
struct EngineDiagnostics: Equatable, Sendable {
    var accessibilityTimeouts = 0
    var stubbornWindows = 0
    var echoesDropped = 0
    var watchdogTrips = 0
    var rehides = 0
    var refusedParks = 0
}

enum EngineBanner: Equatable, Sendable {
    /// The engine made too many frame changes and froze; every window was restored.
    case watchdogTripped
    /// `state.json` cannot be written, so no window is parked.
    case cannotJournal
}

struct EngineState: Equatable, Sendable {
    var model: VirtualWorkspaceModel
    var config = EngineConfig()
    var displays: [DisplayInfo] = []
    var windows: [WindowID: TrackedWindow] = [:]
    var parked: [WindowID: ParkRecord] = [:]
    var expected: [WindowID: ExpectedFrame] = [:]
    /// Windows that refused the size they were given; never retried.
    var stubborn: Set<WindowID> = []
    var rehides: [WindowID: Int] = [:]
    /// Re-hidden too often: left where they are until they are focused.
    var unmanaged: Set<WindowID> = []
    var focused: WindowID?
    /// The generation of the newest batch of frame changes; each batch gets the next number.
    var generation = 0
    /// The newest generation that asked for a frame of each window; older results are stale.
    var latest: [WindowID: Int] = [:]
    /// The watchdog tripped: nothing moves until `restoreAll` / `unfreeze`.
    var isFrozen = false
    /// Whether the journal can be written; without it no window is parked.
    var canJournal = true
    var diagnostics = EngineDiagnostics()

    init(workspaceCount: Int = WindowsSettings.defaultWorkspaceCount, displays: [DisplayInfo] = []) {
        self.displays = displays
        self.model = VirtualWorkspaceModel(workspaceCount: workspaceCount, displays: displays.map(\.uuid))
    }
}

enum FramePurpose: Equatable, Sendable {
    case park
    case restore
    case place
}

struct FrameRequest: Equatable, Sendable {
    var id: WindowID
    var frame: CGRect
    var generation: Int
    var purpose: FramePurpose
}

/// What happened to one `FrameRequest`.
struct FrameResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Applied; the frame read back.
        case applied(CGRect)
        case failed(WindowClientError)
        /// Not attempted because the journal could not be written first.
        case blocked
    }

    var request: FrameRequest
    var outcome: Outcome
}

/// What a UI that shows the workspaces needs after a change.
struct WorkspaceSummary: Equatable, Sendable {
    var current: WorkspaceID?
    /// The workspace each display shows, by display UUID.
    var visible: [String: WorkspaceID]
    var counts: [WorkspaceID: Int]
}

enum EngineCommand: Equatable, Sendable {
    case showWorkspace(WorkspaceID)
    case nextWorkspace
    case previousWorkspace
    case backAndForth
    /// Moves the focused window to a workspace.
    case moveFocusedWindow(to: WorkspaceID)
    case setWorkspaceCount(Int)
    /// Puts every parked window back and unfreezes the engine.
    case restoreAll
}

enum EngineInput: Equatable, Sendable {
    /// Everything at once: the first look, a Space change, a refresh.
    /// `processStarts` gives the start time of every process that owns a window, by pid.
    case snapshot(
        windows: [WindowInfo], displays: [DisplayInfo], focused: WindowID?, processStarts: [Int32: Double],
        now: Double)
    case windowAppeared(WindowInfo, processStart: Double?, now: Double)
    case windowGone(WindowID, now: Double)
    case windowMoved(WindowID, frame: CGRect, now: Double)
    case windowFocused(WindowID?, now: Double)
    case displaysChanged([DisplayInfo], now: Double)
    case command(EngineCommand, now: Double)
    case applied([FrameResult], now: Double)
    case watchdogTripped(now: Double)
    case configChanged(EngineConfig)
    /// The journal could not be written (or can be again).
    case journalAvailability(Bool)
    /// Asks the engine to place a window at a frame, as a layout does (phases 2 and 3).
    case place(WindowID, CGRect, now: Double)
}

enum EngineEffect: Equatable, Sendable {
    /// Written through before any following `setFrame` of `.park` purpose; when it fails those are blocked.
    case journalPark([HiddenEntry])
    case journalRemove(Set<WindowID>)
    case setFrame(FrameRequest)
    case focus(WindowID)
    case saveOrder([WorkspaceID: [WindowID]])
    /// A switch happened: the HUD shows the workspace and its window count.
    case hud(workspace: WorkspaceID, windowCount: Int)
    /// The strip and anything else that shows the workspaces must redraw.
    case summaryChanged(WorkspaceSummary)
    case banner(EngineBanner)
}
