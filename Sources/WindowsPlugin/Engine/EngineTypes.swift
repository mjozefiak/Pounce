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
    /// The workspace new windows of an app start on (active workspace rules only; `RuleResolver`).
    var appWorkspaces: [String: WorkspaceID] = [:]
    /// A window that is re-hidden more than this many times is left alone until it is focused.
    var rehideCap = 3
    /// A move or resize event within this many points of a frame the engine set is our own echo.
    var echoTolerance: CGFloat = 2
    /// How long, in seconds, an expected frame suppresses echoes.
    var echoWindow: Double = 0.5
    /// How much of a parked window stays on its display. Unmeasured (ADR 0009, row 3); one place to change.
    var parkSliver: CGFloat = 1
    /// Which workspaces are arranged, and how (gaps, root orientation): the defaults and the per-workspace
    /// overrides. Tiling arranges only workspaces whose resolved kind is Auto-tile.
    var layout = LayoutConfig()
    /// Each strategy's own configuration (Zones: assignments, library and defaults), built by the strategy.
    var strategyConfigs: [LayoutKind: AnyLayoutConfig] = [:]
}

/// A window the engine knows. The title is kept in memory only (for the window switcher's search), refreshed
/// whenever the window is read; it is never stored and never logged.
struct TrackedWindow: Equatable, Sendable {
    var id: WindowID
    var bundleID: String?
    var title: String
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

/// The frames the engine has set on one window and not yet heard back from, kept briefly to recognise their echoes.
/// One entry per in-flight request (by generation), so the echo of an older frame that is still travelling is not
/// taken for the user moving the window.
struct ExpectedFrames: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var generation: Int
        var frame: CGRect
        var expires: Double
    }

    /// More in flight than this means something is wrong (a fight); the oldest are forgotten.
    static let capacity = 4

    private(set) var entries: [Entry] = []

    /// Expects `frame` for the request of `generation` (replacing what that request expected before).
    mutating func expect(generation: Int, frame: CGRect, expires: Double) {
        entries.removeAll { $0.generation == generation }
        entries.append(Entry(generation: generation, frame: frame, expires: expires))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// The request is about to be sent: its echo window starts now.
    mutating func restamp(generation: Int, expires: Double) {
        guard let index = entries.firstIndex(where: { $0.generation == generation }) else { return }
        entries[index].expires = expires
    }

    /// The request never applied: its frame must not suppress the next event.
    mutating func forget(generation: Int) {
        entries.removeAll { $0.generation == generation }
    }

    /// Whether `frame` is the newest frame asked for and still expected at `now` (the layout need not ask again).
    /// Older frames still in flight do not count: asking for one of them again is a new request.
    func newestMatches(_ frame: CGRect, now: Double, tolerance: CGFloat) -> Bool {
        guard let newest = entries.last else { return false }
        return newest.expires >= now && FrameMath.approximatelyEqual(frame, newest.frame, tolerance: tolerance)
    }

    /// Whether `frame` is the echo of one of the frames still expected at `now`.
    func matches(_ frame: CGRect, now: Double, tolerance: CGFloat) -> Bool {
        entries.contains { $0.expires >= now && FrameMath.approximatelyEqual(frame, $0.frame, tolerance: tolerance) }
    }
}

/// Counters for *Copy diagnostics*: counts only, no titles and no bundle ids.
struct EngineDiagnostics: Equatable, Sendable {
    var accessibilityTimeouts = 0
    var stubbornWindows = 0
    var echoesDropped = 0
    var watchdogTrips = 0
    var rehides = 0
    var refusedParks = 0
    /// Focus-dependent commands whose system focus differed from what the engine believed (a count, no ids).
    var focusMismatches = 0
    /// Focus reads that did not answer in time before a focus-dependent command.
    var focusReadTimeouts = 0
}

/// A command the engine refused to run, which the user should be told about.
enum EngineNotice: Equatable, Sendable {
    /// A command that acts on the focused window found none the user can see.
    case noFocusedWindow
    /// *Move workspace to next display* with one display connected: nothing changed.
    case singleDisplay
}

/// The window the engine asked the system to focus and has not heard back from yet. An observation of the system
/// focus that still shows the old, hidden window does not override it (spec: Phase 0, precedence).
struct PendingFocus: Equatable, Sendable {
    var id: WindowID
    var expires: Double

    /// How long, in engine time, the system is given to catch up with a focus change the engine asked for.
    static let lifetime: Double = 1
}

enum EngineBanner: Equatable, Sendable {
    /// The engine made too many frame changes and froze; every window was restored.
    case watchdogTripped
    /// `state.json` cannot be written, so no window is parked.
    case cannotJournal
}

/// Everything the reducer knows. Its fields fall into clusters, which are the next refactor (not done now: about 150
/// sites read them, so grouping would only move names): *workspaces and displays* (`model`, `displays`,
/// `displayKeys`, `config`); *tracking* (`windows`, `focused`, `previousFocus`, `floating`, `unmanaged`); *parking
/// and the frame ledger* (`parked`, `expected`, `latest`, `generation`, `stubborn`, `tileSizes`, `rehides`,
/// `isFrozen`, `canJournal`); *layout* (`layouts`, `placementHints`); and *diagnostics*. Each reducer part reads the
/// clusters it needs and writes only its own (`ReducerLayeringTests` keeps the parts in layers).
struct EngineState: Equatable, Sendable {
    var model: VirtualWorkspaceModel
    var config = EngineConfig()
    var displays: [DisplayInfo] = [] {
        didSet { displayKeys = DisplayKeys.keys(for: displays).keys }
    }
    /// The key of each display (`DisplayKeys`), kept with `displays` so loops do not recompute it.
    private(set) var displayKeys: [UInt32: String] = [:]
    var windows: [WindowID: TrackedWindow] = [:]
    var parked: [WindowID: ParkRecord] = [:]
    var expected: [WindowID: ExpectedFrames] = [:]
    /// Windows that refused the size they were given; never retried.
    var stubborn: Set<WindowID> = []
    /// The tile size each window was last asked for; a stubborn window gets one new try when it changes.
    var tileSizes: [WindowID: CGSize] = [:]
    var rehides: [WindowID: Int] = [:]
    /// Re-hidden too often: left where they are until they are focused.
    var unmanaged: Set<WindowID> = []
    var focused: WindowID?
    /// The window that had the focus before `focused`; where a new window goes when it took the focus itself.
    var previousFocus: WindowID?
    /// The windows in the order they were focused, the newest last (memory only, never stored). The most recently
    /// used window of a workspace is the newest entry that belongs to it, so a window that moves takes its recency
    /// with it. A cold start has none and a workspace then falls back to its own order.
    var focusOrder: [WindowID] = []
    /// The target of the engine's latest focus request until the system confirms it or `PendingFocus.lifetime` ends.
    var pendingFocus: PendingFocus?
    /// The state of every layout kind of each workspace, by the kind's name. A kind's state survives a switch to
    /// another kind and is brought up to date with the live windows when its kind is used again.
    var layouts: [WorkspaceID: [String: AnyLayoutState]] = [:]
    /// Placement memory of the strategies, keyed by app (memory only; never stored and never logged).
    var placementHints: [String: Int] = [:]
    /// Windows the user took out of tiling (*Toggle floating*): not arranged, not in a tree.
    var floating: Set<WindowID> = []
    /// The generation of the newest batch of frame changes; each batch gets the next number.
    var generation = 0
    /// The newest generation that asked for a frame of each window; older results are stale.
    var latest: [WindowID: Int] = [:]
    /// The watchdog tripped: nothing moves until `restoreAll` / `unfreeze`.
    var isFrozen = false
    /// Processes that did not answer (a park timed out, or a snapshot could not read them): the next event from one
    /// of their windows means it answers again, so parking is reconciled then (`EngineReducer`).
    var unresponsive: Set<Int32> = []
    /// Processes the engine holds no window of that did not answer the latest snapshot: whatever windows they have
    /// are not known yet. The engine looks again a bounded number of times (`WindowEngine.untrackedRetryLimit`).
    var unknownApps: Set<Int32> = []
    /// Whether the journal can be written; without it no window is parked.
    var canJournal = true
    var diagnostics = EngineDiagnostics()

    init(workspaceCount: Int = WindowsSettings.defaultWorkspaceCount, displays: [DisplayInfo] = []) {
        self.displays = displays
        self.displayKeys = DisplayKeys.keys(for: displays).keys
        self.model = VirtualWorkspaceModel(
            workspaceCount: workspaceCount, displays: DisplayKeys.orderedKeys(for: displays))
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
    /// The display the keyboard focus is on: the one the zone layout commands act on.
    var focusedDisplay: String?
}

enum EngineCommand: Equatable, Sendable {
    case showWorkspace(WorkspaceID)
    case nextWorkspace
    case previousWorkspace
    case backAndForth
    /// Gives the current workspace to the next display (wrapping around) and the workspace shown there to the
    /// display it came from.
    case moveWorkspaceToNextDisplay
    /// Moves the focused window to a workspace.
    case moveFocusedWindow(to: WorkspaceID)
    case setWorkspaceCount(Int)
    /// Shows the workspace of a window and focuses it (the window switcher's Return).
    case goToWindow(WindowID)
    /// Moves a window to the current workspace and focuses it (the window switcher's ⌘Return).
    case bringWindowHere(WindowID)
    /// Puts every parked window back and unfreezes the engine.
    case restoreAll
    /// *Reset state*: puts every parked window back, forgets the workspace membership and the layout states, and
    /// gives every window to the workspace shown on its display again. The journal is never touched.
    case resetState
    /// Takes the focused window out of tiling, or puts it back in.
    case toggleFloating
    /// A command of the layout kind of the window's workspace (the focused window when `on` is `nil`): the engine
    /// and the reducer know no verb, the strategy of the kind decides what the id and payload mean.
    case layout(LayoutCommand, on: WindowID? = nil)
    /// A setting changed (sent right after `configChanged`): apps that joined the floating list are let go and
    /// the windows are arranged again.
    case reload
}

extension EngineCommand {
    /// Whether the command acts on the window that has the focus, so the runtime reads the system focus first.
    var readsFocus: Bool {
        switch self {
        case .moveFocusedWindow, .toggleFloating: true
        case .layout(_, let window): window == nil
        default: false
        }
    }

    /// Whether the command is refused (with a HUD) when no visible managed window has the focus. Focus and resize
    /// stay tolerant: they count from the last managed window.
    var needsFocusedWindow: Bool {
        switch self {
        case .moveFocusedWindow, .toggleFloating: true
        case .layout(let command, let window): window == nil && command.id == LayoutCommand.moveID
        default: false
        }
    }
}

enum EngineInput: Equatable, Sendable {
    /// Everything at once: the first look, a Space change, a refresh.
    /// `processStarts` gives the start time of every process that owns a window, by pid. `unreachable` names the
    /// processes whose windows could not be read (an app that does not answer): a window of such a process that is
    /// missing from `windows` is not gone, only unknown, so the engine keeps it and tries again on the next event.
    /// `unreadable` names windows the app listed but whose attributes could not be read this time (same rule).
    case snapshot(
        windows: [WindowInfo], displays: [DisplayInfo], focused: WindowID?, processStarts: [Int32: Double],
        unreachable: Set<Int32> = [], unreadable: Set<WindowID> = [], now: Double)
    case windowAppeared(WindowInfo, processStart: Double?, now: Double)
    case windowGone(WindowID, now: Double)
    case windowMoved(WindowID, frame: CGRect, now: Double)
    case windowFocused(WindowID?, now: Double)
    case displaysChanged([DisplayInfo], now: Double)
    case command(EngineCommand, now: Double)
    case applied([FrameResult], now: Double)
    /// A frame change is about to be sent to the app: its echo window starts now, not when it was queued.
    case frameStarted(FrameRequest, now: Double)
    case watchdogTripped(now: Double)
    case configChanged(EngineConfig)
    /// The journal could not be written (or can be again).
    case journalAvailability(Bool)
    /// Asks the engine to place a window at a frame, as a layout does.
    case place(WindowID, CGRect, now: Double)
    /// What the system says has the focus right now, read just before a command that acts on the focused window. It
    /// changes `focused` only; unlike `windowFocused` it never switches workspace.
    case focusObserved(WindowID?, now: Double)
    /// The system did not answer the focus read in time (a count for the diagnostics).
    case focusReadTimedOut(now: Double)
    /// The layout states stored by an earlier run, before the first snapshot.
    case restoreLayouts([WorkspaceID: [String: JSONValue]])
}

extension EngineInput {
    /// The time the input carries, if any.
    var moment: Double? {
        switch self {
        case .snapshot(_, _, _, _, _, _, let now), .windowAppeared(_, _, let now), .windowGone(_, let now),
            .windowMoved(_, _, let now), .windowFocused(_, let now), .displaysChanged(_, let now),
            .command(_, let now), .applied(_, let now), .frameStarted(_, let now), .watchdogTripped(let now),
            .place(_, _, let now), .focusObserved(_, let now), .focusReadTimedOut(let now):
            now
        case .configChanged, .journalAvailability, .restoreLayouts:
            nil
        }
    }
}

enum EngineEffect: Equatable, Sendable {
    /// Written through before any following `setFrame` of `.park` purpose; when it fails those are blocked.
    case journalPark([HiddenEntry])
    case journalRemove(Set<WindowID>)
    case setFrame(FrameRequest)
    case focus(WindowID)
    case saveOrder([WorkspaceID: [WindowID]])
    case saveLayouts([WorkspaceID: [String: AnyLayoutState]])
    /// The user moved a managed window of a shown Zones workspace (not our own echo): the snap overlay's drag
    /// detector looks at the pointer. Dropped, like every effect that acts, while Accessibility is off.
    case userMovedWindow(WindowID, frame: CGRect)
    /// A switch happened: the HUD shows the workspace and its window count.
    case hud(workspace: WorkspaceID, windowCount: Int)
    /// The strip and anything else that shows the workspaces must redraw.
    case summaryChanged(WorkspaceSummary)
    case banner(EngineBanner)
    /// A command was refused; the HUD says why.
    case notice(EngineNotice)
}
