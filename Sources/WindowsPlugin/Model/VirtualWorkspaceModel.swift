import Foundation
import LintelKit

/// A workspace number, 1 to 9 (the upper bound of the design, `WindowsSettings.maximumWorkspaces`). UI text says
/// "Workspace", code says `VirtualWorkspace…` because `PluginContext.workspace` and the main window's
/// `WorkspaceSection` already mean other things.
struct WorkspaceID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    let rawValue: Int

    /// `nil` outside 1 through 9.
    init?(_ rawValue: Int) {
        guard (WindowsSettings.minimumWorkspaces...WindowsSettings.maximumWorkspaces).contains(rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    static func < (lhs: WorkspaceID, rhs: WorkspaceID) -> Bool { lhs.rawValue < rhs.rawValue }
    var description: String { String(rawValue) }

    /// The workspaces 1 through `count`.
    static func all(count: Int) -> [WorkspaceID] {
        let upper = min(WindowsSettings.maximumWorkspaces, max(0, count))
        return (1...max(1, upper)).compactMap(WorkspaceID.init)
    }
}

/// Which workspaces became hidden and which became visible after a change of the model; the engine turns it into
/// parking and restoring. Both lists are sorted.
struct WorkspaceChange: Equatable, Sendable {
    var hidden: [WorkspaceID] = []
    var shown: [WorkspaceID] = []
    /// The display that has focus after the change.
    var focusedDisplay: String?

    var isEmpty: Bool { hidden.isEmpty && shown.isEmpty }
}

/// The workspaces, which window belongs to which, and which workspace each display shows (pure values, no I/O;
/// spec: Proposed Solution, "Workspaces", Q9). A window belongs to exactly one workspace. Each display shows one
/// workspace; workspaces are global, so a workspace shown on another display is focused there instead of being
/// moved. Displays are keyed by their stable UUID string (`DisplayInfo.uuid`).
struct VirtualWorkspaceModel: Equatable, Sendable {
    private(set) var workspaceCount: Int
    /// The displays in a stable order; the first is the main display.
    private(set) var displays: [String]
    /// The workspace each display shows. A display with no entry shows none (more displays than workspaces).
    private(set) var visible: [String: WorkspaceID]
    private(set) var focusedDisplay: String?
    /// The workspace shown on the focused display before the last switch, for back-and-forth.
    private(set) var previous: WorkspaceID?
    private(set) var membership: [WindowID: WorkspaceID] = [:]
    /// Windows of each workspace in the order they joined it (also the order stored in `state.json`).
    private(set) var order: [WorkspaceID: [WindowID]] = [:]

    /// - Parameters:
    ///   - displays: the connected displays, main first; the lowest numbered workspaces are shown on them in
    ///     order (workspace 1 on the first display, and so on).
    init(workspaceCount: Int, displays: [String]) {
        self.workspaceCount = min(
            WindowsSettings.maximumWorkspaces, max(WindowsSettings.minimumWorkspaces, workspaceCount))
        self.displays = Self.unique(displays)
        self.visible = [:]
        self.focusedDisplay = self.displays.first
        let all = WorkspaceID.all(count: self.workspaceCount)
        for (index, display) in self.displays.enumerated() where index < all.count {
            visible[display] = all[index]
        }
    }

    // MARK: Queries

    var workspaces: [WorkspaceID] { WorkspaceID.all(count: workspaceCount) }

    func workspace(of window: WindowID) -> WorkspaceID? { membership[window] }
    func windows(in workspace: WorkspaceID) -> [WindowID] { order[workspace] ?? [] }
    func isVisible(_ workspace: WorkspaceID) -> Bool { visible.values.contains(workspace) }
    func displayShowing(_ workspace: WorkspaceID) -> String? {
        displays.first { visible[$0] == workspace }
    }

    /// The workspace on the focused display.
    var current: WorkspaceID? { focusedDisplay.flatMap { visible[$0] } }

    /// Every window whose workspace is not shown on any display.
    var hiddenWindows: [WindowID] {
        workspaces.filter { !isVisible($0) }.flatMap { windows(in: $0) }
    }

    func windowCount(in workspace: WorkspaceID) -> Int { windows(in: workspace).count }

    // MARK: Switching

    /// Shows `workspace` on the focused display. When it is shown on another display, that display gets the
    /// focus and nothing is hidden. Showing the workspace that is already current changes nothing.
    @discardableResult
    mutating func show(_ workspace: WorkspaceID) -> WorkspaceChange {
        guard workspaces.contains(workspace) else { return WorkspaceChange(focusedDisplay: focusedDisplay) }
        if let owner = displayShowing(workspace) {
            if owner != focusedDisplay {
                previous = current
                focusedDisplay = owner
            }
            return WorkspaceChange(focusedDisplay: focusedDisplay)
        }
        guard let display = focusedDisplay else { return WorkspaceChange() }
        var change = WorkspaceChange(focusedDisplay: display)
        if let old = visible[display] {
            change.hidden = [old]
            previous = old
        }
        visible[display] = workspace
        change.shown = [workspace]
        return change
    }

    /// Back and forth: shows the workspace shown before the last switch. Nothing happens without one.
    @discardableResult
    mutating func back() -> WorkspaceChange {
        guard let target = previous, workspaces.contains(target) else {
            return WorkspaceChange(focusedDisplay: focusedDisplay)
        }
        return show(target)
    }

    /// The next workspace by number, wrapping around.
    @discardableResult
    mutating func next() -> WorkspaceChange { step(by: 1) }

    @discardableResult
    mutating func previousByNumber() -> WorkspaceChange { step(by: -1) }

    private mutating func step(by delta: Int) -> WorkspaceChange {
        guard let current else { return WorkspaceChange(focusedDisplay: focusedDisplay) }
        let count = workspaceCount
        let index = (current.rawValue - 1 + delta + count) % count
        guard let target = WorkspaceID(index + 1) else { return WorkspaceChange(focusedDisplay: focusedDisplay) }
        return show(target)
    }

    /// *Move workspace to next display*: the workspace on the focused display goes to the next display (wrapping
    /// around), the workspace shown there (if any) goes to the display it came from, and the next display has the
    /// focus, so the current workspace stays the same one. Nothing happens with fewer than two displays or when
    /// the focused display shows no workspace; returns whether it changed.
    @discardableResult
    mutating func moveCurrentToNextDisplay() -> Bool {
        guard displays.count > 1, let source = focusedDisplay, let moving = visible[source],
            let index = displays.firstIndex(of: source)
        else { return false }
        let target = displays[(index + 1) % displays.count]
        visible[source] = visible[target]
        visible[target] = moving
        focusedDisplay = target
        return true
    }

    /// Gives the focus to another display without changing what any display shows.
    mutating func focusDisplay(_ display: String) {
        guard displays.contains(display), display != focusedDisplay else { return }
        previous = current
        focusedDisplay = display
    }

    // MARK: Membership

    /// Adds a window to `workspace`, or when none is given to the workspace shown on `display` (the display it
    /// appeared on), else on the focused display, else workspace 1. A window already known is left where it is.
    @discardableResult
    mutating func add(_ window: WindowID, to workspace: WorkspaceID? = nil, onDisplay display: String? = nil)
        -> WorkspaceID
    {
        if let existing = membership[window] { return existing }
        let target =
            workspace.flatMap { workspaces.contains($0) ? $0 : nil }
            ?? display.flatMap { visible[$0] }
            ?? current
            ?? workspaces[0]
        membership[window] = target
        order[target, default: []].append(window)
        return target
    }

    /// Removes a window, for example when it closed.
    mutating func remove(_ window: WindowID) {
        guard let workspace = membership.removeValue(forKey: window) else { return }
        order[workspace]?.removeAll { $0 == window }
        if order[workspace]?.isEmpty == true { order[workspace] = nil }
    }

    /// Moves a window to another workspace, at its end. Unknown windows and workspaces are ignored. Returns
    /// whether it changed which workspaces' windows are visible, so the engine parks or restores it.
    @discardableResult
    mutating func move(_ window: WindowID, to workspace: WorkspaceID) -> Bool {
        guard let old = membership[window], old != workspace, workspaces.contains(workspace) else { return false }
        order[old]?.removeAll { $0 == window }
        if order[old]?.isEmpty == true { order[old] = nil }
        membership[window] = workspace
        order[workspace, default: []].append(window)
        return true
    }

    /// Windows that no longer exist are dropped and new windows join the workspace shown on their display.
    /// `live` pairs each current window with the display it is on (`nil` when unknown).
    mutating func reconcile(live: [(window: WindowID, display: String?)]) {
        let liveIDs = Set(live.map(\.window))
        for window in membership.keys where !liveIDs.contains(window) { remove(window) }
        for item in live { add(item.window, onDisplay: item.display) }
    }

    // MARK: Configuration changes

    /// Changes the number of workspaces. Windows of the workspaces that go away join the last remaining one; a
    /// display that showed one of them shows the lowest workspace no display shows (or none).
    mutating func setWorkspaceCount(_ count: Int) {
        let newCount = min(WindowsSettings.maximumWorkspaces, max(WindowsSettings.minimumWorkspaces, count))
        guard newCount != workspaceCount else { return }
        let oldCount = workspaceCount
        workspaceCount = newCount
        guard newCount < oldCount, let last = WorkspaceID(newCount) else { return }
        for number in (newCount + 1)...oldCount {
            guard let gone = WorkspaceID(number) else { continue }
            for window in order[gone] ?? [] {
                membership[window] = last
                order[last, default: []].append(window)
            }
            order[gone] = nil
        }
        if let previous, previous.rawValue > newCount { self.previous = nil }
        for display in displays {
            if let shown = visible[display], shown.rawValue > newCount {
                visible[display] = nil
                visible[display] = lowestUnshown()
            }
        }
    }

    /// Displays came or went. A new display shows the lowest workspace no display shows; the workspace of a
    /// removed display becomes hidden (its windows are parked until it is shown again). The focus moves to the
    /// main display when the focused display went away.
    mutating func setDisplays(_ keys: [String]) {
        let newDisplays = Self.unique(keys)
        guard newDisplays != displays else { return }
        let removed = displays.filter { !newDisplays.contains($0) }
        for display in removed { visible[display] = nil }
        displays = newDisplays
        for display in newDisplays where visible[display] == nil {
            visible[display] = lowestUnshown()
        }
        if let focus = focusedDisplay, !newDisplays.contains(focus) { previous = nil }
        if focusedDisplay.map({ newDisplays.contains($0) }) != true { focusedDisplay = newDisplays.first }
    }

    private func lowestUnshown() -> WorkspaceID? {
        workspaces.first { !isVisible($0) }
    }

    // MARK: Restoring

    /// Rebuilds the model from the stored membership (`state.json`): `order` lists the windows of each workspace,
    /// workspaces above `workspaceCount` and duplicate windows are dropped.
    mutating func restore(order stored: [WorkspaceID: [WindowID]]) {
        membership = [:]
        order = [:]
        for workspace in stored.keys.sorted() where workspaces.contains(workspace) {
            for window in stored[workspace] ?? [] where membership[window] == nil {
                membership[window] = workspace
                order[workspace, default: []].append(window)
            }
        }
    }

    private static func unique(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }
}
