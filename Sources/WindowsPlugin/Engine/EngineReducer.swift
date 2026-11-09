import CoreGraphics
import Foundation
import LintelKit

/// The engine's one decision function. It reads no clock, no client and no disk: time arrives in the inputs and
/// everything it wants done is returned as effects (spec: Architecture).
///
/// The visible workspaces decide where every managed window should be: on screen when its workspace is shown,
/// parked when it is not. After any change `reconcileParking` compares that with what is parked now and emits
/// the difference, so a command, a display change and a re-hide all take the same path.
enum EngineReducer {
    static func reduce(_ state: EngineState, _ input: EngineInput) -> (EngineState, [EngineEffect]) {
        var context = Context(state: state)
        let oldOrder = state.model.order
        let oldTiling = state.tiling
        let oldSummary = summary(of: state)

        switch input {
        case .snapshot(let windows, let displays, let focused, let processStarts, let now):
            context.snapshot(
                windows: windows, displays: displays, focused: focused, processStarts: processStarts, now: now)
        case .windowAppeared(let info, let processStart, let now):
            context.windowAppeared(info, processStart: processStart, now: now)
        case .windowGone(let id, _):
            context.removeWindow(id)
        case .windowMoved(let id, let frame, let now):
            context.windowMoved(id, frame: frame, now: now)
        case .windowFocused(let id, let now):
            context.windowFocused(id, now: now)
        case .displaysChanged(let displays, let now):
            context.displaysChanged(displays, now: now)
        case .command(let command, let now):
            context.perform(command, now: now)
        case .applied(let results, let now):
            context.applied(results, now: now)
        case .watchdogTripped(let now):
            context.watchdogTripped(now: now)
        case .configChanged(let config):
            context.state.config = config
        case .journalAvailability(let available):
            context.state.canJournal = available
        case .place(let id, let rect, let now):
            context.place(id, rect, now: now)
        case .restoreTiling(let trees):
            context.state.tiling = trees.filter { context.state.model.workspaces.contains($0.key) }
        }

        context.arrangeIfRequested(now: input.moment ?? 0)
        context.flush()
        if context.state.model.order != oldOrder {
            context.effects.append(.saveOrder(context.state.model.order))
        }
        if context.state.tiling != oldTiling {
            context.effects.append(.saveTiling(context.state.tiling))
        }
        let newSummary = summary(of: context.state)
        if newSummary != oldSummary {
            context.effects.append(.summaryChanged(newSummary))
        }
        return (context.state, context.effects)
    }

    static func summary(of state: EngineState) -> WorkspaceSummary {
        WorkspaceSummary(
            current: state.model.current,
            visible: state.model.visible,
            counts: Dictionary(
                uniqueKeysWithValues: state.model.workspaces.map { ($0, state.model.windowCount(in: $0)) })
        )
    }

    /// Whether the engine arranges a window at all: a standard window of a regular app that is neither minimised
    /// nor fullscreen and not on the floating list.
    static func isManaged(_ info: WindowInfo, config: EngineConfig) -> Bool {
        guard info.isStandard, !info.isMinimized, !info.isFullscreen else { return false }
        if let bundleID = info.bundleID, config.floatingBundleIDs.contains(bundleID) { return false }
        return true
    }

    // MARK: Working state of one reduction

    private struct Context {
        var state: EngineState
        var effects: [EngineEffect] = []
        /// Effects that follow the journal and the frame changes (a HUD, a banner, a focus change).
        private var trailing: [EngineEffect] = []
        /// Entries to journal and frame requests of this reduction, flushed in that order.
        private var journal: [HiddenEntry] = []
        private var requests: [FrameRequest] = []
        private var generation: Int?
        /// Set by every input that can change what tiling should do; `arrangeIfRequested` then runs once.
        private var arrangeRequested = false

        init(state: EngineState) {
            self.state = state
        }

        // MARK: Batches

        private mutating func request(
            _ id: WindowID, _ frame: CGRect, _ purpose: FramePurpose, now: Double
        ) {
            let generation = self.generation ?? state.generation + 1
            self.generation = generation
            state.generation = generation
            state.latest[id] = generation
            state.expected[id] = ExpectedFrame(frame: frame, expires: now + state.config.echoWindow)
            // A newer request for the same window in this reduction replaces the older one.
            requests.removeAll { $0.id == id }
            requests.append(FrameRequest(id: id, frame: frame, generation: generation, purpose: purpose))
        }

        mutating func flush() {
            if !journal.isEmpty { effects.append(.journalPark(journal)) }
            for request in requests { effects.append(.setFrame(request)) }
            effects.append(contentsOf: trailing)
            journal = []
            requests = []
            trailing = []
            generation = nil
        }

        // MARK: Parking

        private func displays() -> [DisplayInfo] { state.displays }

        private mutating func park(_ id: WindowID, now: Double) {
            guard var window = state.windows[id], let start = window.processStart, state.parked[id] == nil,
                !displays().isEmpty
            else { return }
            let parked = FrameMath.parkedFrame(for: window.frame, displays: displays(), sliver: state.config.parkSliver)
            state.parked[id] = ParkRecord(home: window.frame, parkedFrame: parked, processStart: start)
            journal.append(
                HiddenEntry(windowID: id, processStart: start, homeFrame: FrameRecord(window.frame)))
            window.frame = parked
            state.windows[id] = window
            request(id, parked, .park, now: now)
        }

        /// Puts a parked window back: onto its tile when its workspace is tiled, else to where it was.
        private mutating func restore(_ id: WindowID, now: Double, tiled: Bool = true) {
            guard let record = state.parked[id] else { return }
            let frame =
                (tiled ? tileTarget(for: id) : nil)
                ?? FrameMath.restoredFrame(home: record.home, displays: displays())
            request(id, frame, .restore, now: now)
        }

        /// Parks the windows of hidden workspaces and restores the windows of shown ones.
        mutating func reconcileParking(now: Double) {
            guard !state.isFrozen else { return }
            for (id, _) in state.windows.sorted(by: { $0.key < $1.key }) where !state.unmanaged.contains(id) {
                guard let workspace = state.model.workspace(of: id) else { continue }
                if state.model.isVisible(workspace) {
                    if state.parked[id] != nil { restore(id, now: now) }
                } else if state.parked[id] == nil {
                    guard state.canJournal else {
                        trailing.append(.banner(.cannotJournal))
                        continue
                    }
                    park(id, now: now)
                }
            }
        }

        // MARK: Inputs

        mutating func snapshot(
            windows: [WindowInfo], displays: [DisplayInfo], focused: WindowID?, processStarts: [Int32: Double],
            now: Double
        ) {
            state.displays = displays
            state.model.setDisplays(displays.map(\.uuid))
            state.focused = focused
            let live = windows.filter { EngineReducer.isManaged($0, config: state.config) }
            let liveIDs = Set(live.map(\.id))
            for id in Array(state.windows.keys) where !liveIDs.contains(id) { removeWindow(id) }
            for info in live {
                if state.windows[info.id] == nil {
                    track(info, processStart: processStarts[info.id.pid])
                } else if state.parked[info.id] == nil {
                    if let start = processStarts[info.id.pid] { state.windows[info.id]?.processStart = start }
                    state.windows[info.id]?.frame = info.frame
                } else {
                    // A parked window that is somewhere else now: it came back on its own.
                    windowMoved(info.id, frame: info.frame, now: now)
                }
            }
            reconcileParking(now: now)
            arrangeRequested = true
        }

        /// Starts tracking a window and gives it a workspace. A window without a known process start is tracked
        /// but never parked.
        private mutating func track(_ info: WindowInfo, processStart: Double?) {
            let previous = state.windows[info.id]
            state.windows[info.id] = TrackedWindow(
                id: info.id, bundleID: info.bundleID, frame: info.frame,
                processStart: processStart ?? previous?.processStart)
            let display = FrameMath.display(for: info.frame, in: displays())?.uuid
            state.model.add(info.id, onDisplay: display)
        }

        mutating func windowAppeared(_ info: WindowInfo, processStart: Double?, now: Double) {
            guard EngineReducer.isManaged(info, config: state.config) else {
                // A window that stopped being managed (minimised, fullscreen, now floating) is let go.
                if state.windows[info.id] != nil { releaseUnmanaged(info.id, now: now) }
                return
            }
            if state.windows[info.id] == nil {
                track(info, processStart: processStart)
                arrangeRequested = true
            } else {
                if let processStart { state.windows[info.id]?.processStart = processStart }
                if state.parked[info.id] == nil { state.windows[info.id]?.frame = info.frame }
            }
            reconcileParking(now: now)
        }

        /// A window the engine no longer manages is put back (when parked) and forgotten.
        private mutating func releaseUnmanaged(_ id: WindowID, now: Double) {
            // A parked window keeps its parked record until the restore result arrives and clears its journal
            // entry, so the record is the only thing kept.
            if state.parked[id] != nil { restore(id, now: now, tiled: false) }
            state.model.remove(id)
            state.windows[id] = nil
            state.floating.remove(id)
            if state.previousFocus == id { state.previousFocus = nil }
            arrangeRequested = true
            state.unmanaged.remove(id)
            state.rehides[id] = nil
            state.stubborn.remove(id)
        }

        mutating func removeWindow(_ id: WindowID) {
            let wasParked = state.parked[id] != nil
            state.model.remove(id)
            state.windows[id] = nil
            state.floating.remove(id)
            if state.previousFocus == id { state.previousFocus = nil }
            arrangeRequested = true
            state.parked[id] = nil
            state.expected[id] = nil
            state.stubborn.remove(id)
            state.rehides[id] = nil
            state.unmanaged.remove(id)
            state.latest[id] = nil
            if state.focused == id { state.focused = nil }
            if wasParked { effects.append(.journalRemove([id])) }
        }

        mutating func windowMoved(_ id: WindowID, frame: CGRect, now: Double) {
            guard state.windows[id] != nil else { return }
            if let expected = state.expected[id], expected.expires >= now,
                FrameMath.approximatelyEqual(frame, expected.frame, tolerance: state.config.echoTolerance)
            {
                state.diagnostics.echoesDropped += 1
                return
            }
            guard let record = state.parked[id] else {
                state.windows[id]?.frame = frame
                return
            }
            if FrameMath.originsApproximatelyEqual(frame, record.parkedFrame, tolerance: state.config.echoTolerance) {
                return
            }
            guard !state.isFrozen else {
                state.windows[id]?.frame = frame
                return
            }
            // A hidden window moved on screen by itself (an app restoring its position).
            if state.focused == id, state.config.followFocus {
                followFocus(of: id, now: now)
                return
            }
            let count = (state.rehides[id] ?? 0) + 1
            state.rehides[id] = count
            state.diagnostics.rehides += 1
            if count > state.config.rehideCap {
                // Stop the fight: leave it where it is until the user focuses it.
                state.unmanaged.insert(id)
                state.parked[id] = nil
                state.windows[id]?.frame = frame
                effects.append(.journalRemove([id]))
                return
            }
            guard !displays().isEmpty else { return }
            let parked = FrameMath.parkedFrame(for: frame, displays: displays(), sliver: state.config.parkSliver)
            state.parked[id]?.parkedFrame = parked
            state.windows[id]?.frame = parked
            request(id, parked, .park, now: now)
        }

        mutating func windowFocused(_ id: WindowID?, now: Double) {
            if let previous = state.focused, previous != id, state.windows[previous] != nil {
                state.previousFocus = previous
            }
            state.focused = id
            guard let id, state.windows[id] != nil else { return }
            state.unmanaged.remove(id)
            state.rehides[id] = nil
            if state.config.followFocus, !state.isFrozen { followFocus(of: id, now: now) }
        }

        /// Switches to the workspace of a window that got focus while its workspace was hidden.
        private mutating func followFocus(of id: WindowID, now: Double) {
            guard let workspace = state.model.workspace(of: id), !state.model.isVisible(workspace) else {
                // Shown, but a parked window may need to come back (it was moved while its workspace was shown).
                if state.parked[id] != nil, state.model.workspace(of: id).map(state.model.isVisible) == true {
                    restore(id, now: now)
                }
                return
            }
            switchTo(workspace, now: now)
        }

        mutating func displaysChanged(_ displays: [DisplayInfo], now: Double) {
            state.displays = displays
            state.model.setDisplays(displays.map(\.uuid))
            arrangeRequested = true
            reconcileParking(now: now)
            guard !state.isFrozen else { return }
            // Parked windows are re-parked in the new corner of their display.
            for (id, record) in state.parked.sorted(by: { $0.key < $1.key }) {
                // A window whose workspace is shown again is being restored, not re-parked.
                if let workspace = state.model.workspace(of: id), state.model.isVisible(workspace) { continue }
                guard !displays.isEmpty else { continue }
                let corner = FrameMath.parkedFrame(
                    for: record.home, displays: displays, sliver: state.config.parkSliver)
                if !FrameMath.originsApproximatelyEqual(corner, record.parkedFrame, tolerance: 0.5) {
                    state.parked[id]?.parkedFrame = corner
                    state.windows[id]?.frame = corner
                    request(id, corner, .park, now: now)
                }
            }
        }

        // MARK: Commands

        private mutating func switchTo(_ workspace: WorkspaceID, now: Double) {
            let hidden = hiddenWindowsIfShown(workspace)
            if !state.canJournal, hidden {
                trailing.append(.banner(.cannotJournal))
                return
            }
            let before = state.model.current
            state.model.show(workspace)
            arrangeRequested = true
            reconcileParking(now: now)
            if let current = state.model.current, current != before {
                trailing.append(
                    .hud(workspace: current, windowCount: state.model.windowCount(in: current)))
            }
        }

        /// Whether showing `workspace` would park a window.
        private func hiddenWindowsIfShown(_ workspace: WorkspaceID) -> Bool {
            var probe = state.model
            probe.show(workspace)
            return probe.hiddenWindows.contains { id in
                state.windows[id] != nil && state.parked[id] == nil && !state.unmanaged.contains(id)
            }
        }

        mutating func perform(_ command: EngineCommand, now: Double) {
            arrangeRequested = true
            switch command {
            case .restoreAll:
                restoreAll(now: now)
                return
            case .showWorkspace(let workspace):
                state.isFrozen = false
                switchTo(workspace, now: now)
            case .nextWorkspace, .previousWorkspace:
                guard let current = state.model.current else { return }
                let count = state.model.workspaceCount
                let delta = command == .nextWorkspace ? 1 : count - 1
                guard let target = WorkspaceID((current.rawValue - 1 + delta) % count + 1) else { return }
                state.isFrozen = false
                switchTo(target, now: now)
            case .backAndForth:
                guard let target = state.model.previous else { return }
                state.isFrozen = false
                switchTo(target, now: now)
            case .moveFocusedWindow(let workspace):
                moveFocusedWindow(to: workspace, now: now)
            case .setWorkspaceCount(let count):
                state.model.setWorkspaceCount(count)
                state.tiling = state.tiling.filter { state.model.workspaces.contains($0.key) }
                reconcileParking(now: now)
            case .goToWindow(let id):
                guard state.windows[id] != nil else { return }
                state.isFrozen = false
                if let workspace = state.model.workspace(of: id) { switchTo(workspace, now: now) }
                trailing.append(.focus(id))
            case .reload:
                reload(now: now)
            case .focusDirection(let direction):
                focusTile(direction)
            case .moveInTree(let direction):
                editTree { id, tree in TilingNavigation.move(id, direction, in: tree) }
            case .resize(let delta):
                editTree { id, tree in
                    var next = tree
                    return next.resize(id, by: delta) ? next : nil
                }
            case .join(let direction):
                editTree { id, tree in
                    var next = tree
                    return next.join(id, direction) ? next : nil
                }
            case .toggleOrientation:
                editTree { id, tree in
                    var next = tree
                    return next.toggleOrientation(of: id) ? next : nil
                }
            case .balance:
                editTree { _, tree in
                    var next = tree
                    next.balance()
                    return next == tree ? nil : next
                }
            case .toggleFloating:
                guard !state.isFrozen, let id = state.focused, state.windows[id] != nil else { return }
                if state.floating.remove(id) == nil { state.floating.insert(id) }
            case .bringWindowHere(let id):
                guard state.windows[id] != nil, let current = state.model.current else { return }
                state.isFrozen = false
                if state.model.move(id, to: current) { reconcileParking(now: now) }
                trailing.append(.focus(id))
            }
        }

        private mutating func moveFocusedWindow(to workspace: WorkspaceID, now: Double) {
            guard !state.isFrozen, let id = state.focused, state.windows[id] != nil,
                let old = state.model.workspace(of: id), old != workspace
            else { return }
            if !state.model.isVisible(workspace), !state.canJournal {
                trailing.append(.banner(.cannotJournal))
                return
            }
            guard state.model.move(id, to: workspace) else { return }
            reconcileParking(now: now)
            // The focus goes to what is left on the workspace the window came from.
            if let next = state.model.windows(in: old).last(where: { $0 != id }), state.model.isVisible(old) {
                trailing.append(.focus(next))
            }
        }

        /// Puts every parked window back. The engine then stays still (`isFrozen`) until the next workspace
        /// command, so windows of hidden workspaces that are on screen now are not hidden again behind the
        /// user's back.
        mutating func restoreAll(now: Double) {
            state.isFrozen = true
            for id in state.parked.keys.sorted() { restore(id, now: now) }
        }

        mutating func watchdogTripped(now: Double) {
            state.diagnostics.watchdogTrips += 1
            trailing.append(.banner(.watchdogTripped))
            restoreAll(now: now)
        }

        mutating func place(_ id: WindowID, _ rect: CGRect, now: Double) {
            guard let window = state.windows[id], !state.isFrozen, state.parked[id] == nil else { return }
            let target = state.stubborn.contains(id) ? FrameMath.centered(size: window.frame.size, in: rect) : rect
            request(id, target, .place, now: now)
        }

        // MARK: Tiling

        /// After a setting changed. Windows of apps that just joined the floating list are let go.
        mutating func reload(now: Double) {
            let config = state.config
            for (id, window) in state.windows.sorted(by: { $0.key < $1.key }) {
                if let bundleID = window.bundleID, config.floatingBundleIDs.contains(bundleID) {
                    releaseUnmanaged(id, now: now)
                }
            }
            state.tiling = state.tiling.filter { state.model.workspaces.contains($0.key) }
            arrangeRequested = true
        }

        /// The windows tiling arranges on a workspace, in join order: tracked, not floating, not left alone.
        private func tileable(_ workspace: WorkspaceID) -> [WindowID] {
            state.model.windows(in: workspace).filter {
                state.windows[$0] != nil && !state.floating.contains($0) && !state.unmanaged.contains($0)
            }
        }

        /// Brings the tree of a tiled workspace up to date: windows that are gone, floating or moved away leave
        /// it; new windows enter after the focused window (or the one focused before it), several in join order.
        private mutating func syncTree(_ workspace: WorkspaceID, _ layout: ResolvedLayout) -> TilingTree {
            let wanted = tileable(workspace)
            let wantedSet = Set(wanted)
            var tree = state.tiling[workspace] ?? TilingTree(orientation: layout.rootOrientation)
            for id in tree.windows where !wantedSet.contains(id) { tree.remove(id) }
            if tree.windows.count <= 1 { tree.root.orientation = layout.rootOrientation }
            var anchor: WindowID?
            for id in wanted where !tree.contains(id) {
                if anchor == nil {
                    anchor = [state.focused, state.previousFocus].lazy.compactMap { $0 }
                        .first { $0 != id && tree.contains($0) }
                }
                tree.insert(id, after: anchor)
                anchor = id
            }
            if state.tiling[workspace] != tree { state.tiling[workspace] = tree }
            return tree
        }

        /// The tile of every window of a visible, Auto-tile workspace; nothing for any other workspace.
        private mutating func tileFrames(_ workspace: WorkspaceID) -> [WindowID: CGRect] {
            guard !state.isFrozen, state.model.isVisible(workspace) else { return [:] }
            let layout = state.config.layout.resolved(for: workspace)
            guard layout.kind == .tiling,
                let uuid = state.model.displayShowing(workspace),
                let display = state.displays.first(where: { $0.uuid == uuid })
            else { return [:] }
            let tree = syncTree(workspace, layout)
            return TilingLayout.frames(tree, area: display.visibleFrame, gaps: layout.gaps)
        }

        /// Where a window goes: its tile, or centred in it when the window refused the size it was given.
        private mutating func target(for id: WindowID, tile: CGRect) -> CGRect {
            guard state.stubborn.contains(id), let window = state.windows[id] else { return tile }
            return FrameMath.centered(size: window.frame.size, in: tile)
        }

        private mutating func tileTarget(for id: WindowID) -> CGRect? {
            guard state.windows[id] != nil, let workspace = state.model.workspace(of: id),
                let tile = tileFrames(workspace)[id]
            else { return nil }
            return target(for: id, tile: tile)
        }

        /// The focused window and its workspace when tiling commands apply to it: the engine is not frozen, the
        /// window is managed and tiled, and its workspace is shown and Auto-tile.
        private mutating func focusedTile() -> (workspace: WorkspaceID, window: WindowID)? {
            guard !state.isFrozen, let id = state.focused, state.windows[id] != nil,
                !state.floating.contains(id), !state.unmanaged.contains(id),
                let workspace = state.model.workspace(of: id), state.model.isVisible(workspace),
                tileFrames(workspace)[id] != nil
            else { return nil }
            return (workspace, id)
        }

        private mutating func focusTile(_ direction: TilingDirection) {
            guard let (workspace, id) = focusedTile(), let tree = state.tiling[workspace],
                let next = TilingNavigation.neighbour(of: id, direction, in: tree)
            else { return }
            state.previousFocus = id
            state.focused = next
            trailing.append(.focus(next))
        }

        /// Replaces the tree of the focused window's workspace with what `change` makes of it (`nil`: no change).
        private mutating func editTree(_ change: (WindowID, TilingTree) -> TilingTree?) {
            guard let (workspace, id) = focusedTile(), let tree = state.tiling[workspace],
                let next = change(id, tree)
            else { return }
            state.tiling[workspace] = next
        }

        mutating func arrangeIfRequested(now: Double) {
            guard arrangeRequested else { return }
            arrangeRequested = false
            guard !state.isFrozen else { return }
            for workspace in state.model.workspaces where state.model.isVisible(workspace) {
                let tiles = tileFrames(workspace)
                for id in tiles.keys.sorted() {
                    guard let tile = tiles[id], let window = state.windows[id], state.parked[id] == nil,
                        !state.unmanaged.contains(id), !requests.contains(where: { $0.id == id })
                    else { continue }
                    let frame = target(for: id, tile: tile)
                    let tolerance = state.config.echoTolerance
                    if FrameMath.approximatelyEqual(window.frame, frame, tolerance: tolerance) { continue }
                    if let expected = state.expected[id], expected.expires >= now,
                        FrameMath.approximatelyEqual(expected.frame, frame, tolerance: tolerance)
                    {
                        continue
                    }
                    request(id, frame, .place, now: now)
                }
            }
        }

        // MARK: Results

        mutating func applied(_ results: [FrameResult], now: Double) {
            var cleared = Set<WindowID>()
            for result in results {
                let request = result.request
                let id = request.id
                if let newest = state.latest[id], request.generation < newest { continue }
                switch result.outcome {
                case .applied(let actual):
                    state.expected[id] = ExpectedFrame(frame: actual, expires: now + state.config.echoWindow)
                    if state.windows[id] != nil { state.windows[id]?.frame = actual }
                    switch request.purpose {
                    case .park:
                        state.parked[id]?.parkedFrame = actual
                    case .restore:
                        state.parked[id] = nil
                        cleared.insert(id)
                        checkSize(request, actual: actual, now: now)
                    case .place:
                        checkSize(request, actual: actual, now: now)
                    }
                case .failed(let error):
                    failed(request, error, cleared: &cleared)
                case .blocked:
                    unpark(id)
                    state.diagnostics.refusedParks += 1
                    state.canJournal = false
                    trailing.append(.banner(.cannotJournal))
                }
            }
            if !cleared.isEmpty { effects.append(.journalRemove(cleared)) }
        }

        /// A window that was meant to be parked but was not: back to its home frame in the books.
        private mutating func unpark(_ id: WindowID) {
            if let record = state.parked[id] { state.windows[id]?.frame = record.home }
            state.parked[id] = nil
        }

        private mutating func failed(
            _ request: FrameRequest, _ error: WindowClientError, cleared: inout Set<WindowID>
        ) {
            let id = request.id
            // The frame was never applied, so it must not suppress the next request for it.
            state.expected[id] = nil
            if error == .timedOut { state.diagnostics.accessibilityTimeouts += 1 }
            if error == .windowGone {
                removeWindow(id)
                return
            }
            if request.purpose == .park {
                // It stayed where it was: it is not parked, so its journal entry must go.
                unpark(id)
                cleared.insert(id)
            }
            // A failed restore keeps the window parked and journaled; the next event or snapshot tries again.
        }

        /// A window that did not take the size it was given is stubborn: it is centred in its tile once and
        /// never retried.
        private mutating func checkSize(_ request: FrameRequest, actual: CGRect, now: Double) {
            let id = request.id
            let tolerance = state.config.echoTolerance
            guard
                abs(actual.width - request.frame.width) > tolerance
                    || abs(actual.height - request.frame.height) > tolerance
            else { return }
            guard !state.stubborn.contains(id) else { return }
            state.stubborn.insert(id)
            state.diagnostics.stubbornWindows += 1
            var target = FrameMath.centered(size: actual.size, in: request.frame)
            if let display = FrameMath.display(for: request.frame, in: displays()) {
                target = FrameMath.clamp(target, into: display.visibleFrame)
            }
            self.request(id, target, .place, now: now)
        }
    }
}
