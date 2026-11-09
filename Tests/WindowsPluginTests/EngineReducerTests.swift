import CoreGraphics
import LintelKit
import Testing

@testable import WindowsPlugin

/// The reducer on plain values: no client, no disk, no clock.
@Suite struct EngineReducerTests {
    private let main = FakeWindowClient.mainDisplay
    private let second = FakeWindowClient.secondDisplay
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }
    private func id(_ number: UInt32, pid: Int32 = 100) -> WindowID { WindowID(pid: pid, number: number) }
    private let t0 = 1_000.0

    private func starts(_ pids: [Int32]) -> [Int32: Double] {
        Dictionary(uniqueKeysWithValues: pids.map { ($0, 1_000 + Double($0)) })
    }

    /// A state with the given windows on workspace 1, the focused one first.
    private func state(
        _ windows: [WindowInfo], displays: [DisplayInfo]? = nil, count: Int = 4, focused: WindowID? = nil
    ) -> EngineState {
        var state = EngineState(workspaceCount: count)
        let shown = displays ?? [main]
        let (next, _) = EngineReducer.reduce(
            state,
            .snapshot(
                windows: windows, displays: shown, focused: focused,
                processStarts: starts(Array(Set(windows.map(\.id.pid)))), now: t0))
        state = next
        return state
    }

    private func requests(_ effects: [EngineEffect]) -> [FrameRequest] {
        effects.compactMap { if case .setFrame(let request) = $0 { request } else { nil } }
    }

    private func command(_ state: EngineState, _ command: EngineCommand, now: Double = 1_000) -> (
        EngineState, [EngineEffect]
    ) {
        EngineReducer.reduce(state, .command(command, now: now))
    }

    /// The results the client would return if every request succeeded exactly.
    private func succeed(_ requests: [FrameRequest]) -> [FrameResult] {
        requests.map { FrameResult(request: $0, outcome: .applied($0.frame)) }
    }

    // MARK: Tracking

    @Test func aSnapshotTracksOnlyManagedWindows() {
        let state = state([
            makeWindow(1), makeWindow(2, standard: false), makeWindow(3, minimized: true),
            makeWindow(4, fullscreen: true), makeWindow(5, bundleID: "com.apple.calculator"),
        ])
        #expect(state.windows.keys.sorted() == [id(1)])
        #expect(state.model.windows(in: ws(1)) == [id(1)])
    }

    @Test func aSnapshotEmitsNoFrameChanges() {
        var initial = EngineState(workspaceCount: 4)
        let (next, effects) = EngineReducer.reduce(
            initial,
            .snapshot(windows: [makeWindow(1)], displays: [main], focused: nil, processStarts: starts([100]), now: t0))
        initial = next
        #expect(requests(effects).isEmpty)
        #expect(effects.contains(.saveOrder([ws(1): [id(1)]])))
    }

    @Test func aWindowThatDisappearsFromTheSnapshotIsForgotten() {
        var current = state([makeWindow(1), makeWindow(2)])
        (current, _) = EngineReducer.reduce(
            current,
            .snapshot(windows: [makeWindow(2)], displays: [main], focused: nil, processStarts: starts([100]), now: t0))
        #expect(current.windows.keys.sorted() == [id(2)])
    }

    @Test func aWindowThatBecomesMinimisedIsReleased() {
        var current = state([makeWindow(1)])
        (current, _) = EngineReducer.reduce(
            current, .windowAppeared(makeWindow(1, minimized: true), processStart: 1_100, now: t0))
        #expect(current.windows.isEmpty)
        #expect(current.model.windows(in: ws(1)).isEmpty)
    }

    // MARK: Switching

    @Test func switchingParksTheOldWorkspaceAfterJournalingIt() {
        let home = CGRect(x: 100, y: 100, width: 800, height: 600)
        let start = state([makeWindow(1, frame: home), makeWindow(2, pid: 200, frame: home)])
        let (next, effects) = command(start, .showWorkspace(ws(2)))

        guard case .journalPark(let entries) = effects.first else {
            Issue.record("the journal must come first: \(effects)")
            return
        }
        #expect(entries.map(\.windowID) == [id(1), id(2, pid: 200)])
        #expect(entries.allSatisfy { $0.homeFrame == FrameRecord(home) })
        #expect(entries.map(\.processStart) == [1_100, 1_200])
        let parks = requests(effects)
        #expect(parks.count == 2)
        #expect(parks.allSatisfy { $0.purpose == .park && $0.generation == 1 })
        // Only a sliver of the window stays on the display: the bottom right corner.
        #expect(parks.allSatisfy { $0.frame.origin == CGPoint(x: 1919, y: 1079) && $0.frame.size == home.size })
        #expect(effects.contains(.hud(workspace: ws(2), windowCount: 0)))
        #expect(next.model.current == ws(2))
        #expect(next.parked.keys.sorted() == [id(1), id(2, pid: 200)])
        // The journal effect precedes every frame effect.
        let journalIndex = effects.firstIndex { if case .journalPark = $0 { true } else { false } }
        let firstFrame = effects.firstIndex { if case .setFrame = $0 { true } else { false } }
        #expect(journalIndex! < firstFrame!)
    }

    @Test func backAndForthRestoresTheHomeFramesAndClearsTheJournalOnResult() {
        let home = CGRect(x: 100, y: 100, width: 800, height: 600)
        var current = state([makeWindow(1, frame: home)])
        var effects: [EngineEffect]
        (current, effects) = command(current, .showWorkspace(ws(2)))
        (current, _) = EngineReducer.reduce(current, .applied(succeed(requests(effects)), now: t0))

        (current, effects) = command(current, .backAndForth)
        let restores = requests(effects)
        #expect(restores.map(\.purpose) == [.restore])
        #expect(restores[0].frame == home)
        #expect(!effects.contains { if case .journalRemove = $0 { true } else { false } })

        (current, effects) = EngineReducer.reduce(current, .applied(succeed(restores), now: t0))
        #expect(effects.contains(.journalRemove([id(1)])))
        #expect(current.parked.isEmpty)
        #expect(current.windows[id(1)]?.frame == home)
    }

    @Test func aWindowWithoutAProcessStartIsNeverParked() {
        var current = EngineState(workspaceCount: 4)
        (current, _) = EngineReducer.reduce(
            current, .snapshot(windows: [makeWindow(1)], displays: [main], focused: nil, processStarts: [:], now: t0))
        let (next, effects) = command(current, .showWorkspace(ws(2)))
        #expect(requests(effects).isEmpty)
        #expect(next.parked.isEmpty)
    }

    @Test func withoutAJournalNothingIsParkedAndTheSwitchIsRefused() {
        var current = state([makeWindow(1)])
        (current, _) = EngineReducer.reduce(current, .journalAvailability(false))
        let (next, effects) = command(current, .showWorkspace(ws(2)))
        #expect(effects.contains(.banner(.cannotJournal)))
        #expect(requests(effects).isEmpty)
        #expect(next.model.current == ws(1))
    }

    @Test func aBlockedParkLeavesTheWindowWhereItIsAndStopsParking() {
        var current = state([makeWindow(1)])
        var effects: [EngineEffect]
        (current, effects) = command(current, .showWorkspace(ws(2)))
        let blocked = requests(effects).map { FrameResult(request: $0, outcome: .blocked) }
        (current, effects) = EngineReducer.reduce(current, .applied(blocked, now: t0))
        #expect(current.parked.isEmpty)
        #expect(current.canJournal == false)
        #expect(current.diagnostics.refusedParks == 1)
        #expect(current.windows[id(1)]?.frame == CGRect(x: 100, y: 100, width: 800, height: 600))
        #expect(effects.contains(.banner(.cannotJournal)))
    }

    @Test func showingTheCurrentWorkspaceChangesNothing() {
        let (next, effects) = command(state([makeWindow(1)]), .showWorkspace(ws(1)))
        #expect(requests(effects).isEmpty)
        #expect(!effects.contains { if case .hud = $0 { true } else { false } })
        #expect(next.generation == 0)
    }

    @Test func nextAndPreviousCycleAndBackReturns() {
        var current = state([], count: 3)
        (current, _) = command(current, .nextWorkspace)
        #expect(current.model.current == ws(2))
        (current, _) = command(current, .previousWorkspace)
        (current, _) = command(current, .previousWorkspace)
        #expect(current.model.current == ws(3))
        (current, _) = command(current, .backAndForth)
        #expect(current.model.current == ws(1))
    }

    @Test func movingTheFocusedWindowToAHiddenWorkspaceParksItAndFocusesTheNeighbour() {
        let start = state([makeWindow(1), makeWindow(2)], focused: id(2))
        let (next, effects) = command(start, .moveFocusedWindow(to: ws(3)))
        #expect(next.model.workspace(of: id(2)) == ws(3))
        #expect(requests(effects).map(\.id) == [id(2)])
        #expect(effects.contains(.focus(id(1))))
        #expect(next.parked.keys.sorted() == [id(2)])
    }

    @Test func movingTheFocusedWindowToAVisibleWorkspaceMovesNothing() {
        let start = state([makeWindow(1)], displays: [main, second], focused: id(1))
        let (next, effects) = command(start, .moveFocusedWindow(to: ws(2)))
        #expect(next.model.workspace(of: id(1)) == ws(2))
        #expect(requests(effects).isEmpty)
    }

    @Test func settingTheWorkspaceCountParksWindowsOfAWorkspaceThatLeftTheScreen() {
        var current = state([makeWindow(1)], count: 5)
        (current, _) = command(current, .showWorkspace(ws(5)))
        (current, _) = EngineReducer.reduce(
            current, .windowAppeared(makeWindow(9, pid: 300), processStart: 1_300, now: t0))
        #expect(current.model.workspace(of: id(9, pid: 300)) == ws(5))
        let (next, effects) = command(current, .setWorkspaceCount(3))
        // Workspace 5 is gone, its window joined workspace 3, and the display shows workspace 1 now.
        #expect(next.model.current == ws(1))
        #expect(requests(effects).contains { $0.id == id(9, pid: 300) && $0.purpose == .park })
    }

    // MARK: Echoes, re-hide, follow focus

    private func parkedState() -> (EngineState, FrameRequest) {
        var current = state([makeWindow(1)])
        var effects: [EngineEffect]
        (current, effects) = command(current, .showWorkspace(ws(2)))
        let request = requests(effects)[0]
        (current, _) = EngineReducer.reduce(current, .applied(succeed([request]), now: 1_000))
        return (current, request)
    }

    @Test func ourOwnEchoIsDroppedWithinTheWindowAndCounted() {
        let (current, request) = parkedState()
        let (next, effects) = EngineReducer.reduce(
            current, .windowMoved(id(1), frame: request.frame.offsetBy(dx: 1, dy: 1), now: 1_000.2))
        #expect(effects.isEmpty)
        #expect(next.diagnostics.echoesDropped == 1)
        #expect(next.diagnostics.rehides == 0)
    }

    @Test func aParkedWindowThatMovesByItselfIsHiddenAgain() {
        let (current, _) = parkedState()
        let (next, effects) = EngineReducer.reduce(
            current, .windowMoved(id(1), frame: CGRect(x: 300, y: 300, width: 800, height: 600), now: 1_010))
        let again = requests(effects)
        #expect(again.count == 1)
        #expect(again[0].purpose == .park)
        #expect(again[0].generation == 2)
        #expect(next.rehides[id(1)] == 1)
        #expect(next.diagnostics.rehides == 1)
        // The journal keeps the original home; nothing is journaled again.
        #expect(!effects.contains { if case .journalPark = $0 { true } else { false } })
    }

    @Test func aWindowRehiddenMoreThanThreeTimesIsLeftAloneUntilFocused() {
        var (current, _) = parkedState()
        var effects: [EngineEffect] = []
        for attempt in 1...3 {
            (current, effects) = EngineReducer.reduce(
                current,
                .windowMoved(
                    id(1), frame: CGRect(x: 300, y: 300, width: 800, height: 600), now: 1_010 + Double(attempt)))
            #expect(requests(effects).count == 1, "attempt \(attempt)")
            (current, _) = EngineReducer.reduce(
                current, .applied(succeed(requests(effects)), now: 1_010 + Double(attempt)))
        }
        (current, effects) = EngineReducer.reduce(
            current, .windowMoved(id(1), frame: CGRect(x: 300, y: 300, width: 800, height: 600), now: 1_020))
        #expect(requests(effects).isEmpty)
        #expect(effects.contains(.journalRemove([id(1)])))
        #expect(current.unmanaged == [id(1)])
        #expect(current.parked.isEmpty)

        // Left alone: later moves and switches do not touch it.
        (current, effects) = EngineReducer.reduce(
            current, .windowMoved(id(1), frame: CGRect(x: 10, y: 10, width: 800, height: 600), now: 1_030))
        #expect(requests(effects).isEmpty)
        (current, effects) = command(current, .showWorkspace(ws(3)), now: 1_031)
        #expect(requests(effects).isEmpty)

        // Focusing it brings it back under management and follows it to its workspace.
        (current, effects) = EngineReducer.reduce(current, .windowFocused(id(1), now: 1_040))
        #expect(current.unmanaged.isEmpty)
        #expect(current.model.current == ws(1))
    }

    @Test func aHiddenWindowThatGetsFocusSwitchesToItsWorkspace() {
        let (current, _) = parkedState()
        let (next, effects) = EngineReducer.reduce(current, .windowFocused(id(1), now: 1_005))
        #expect(next.model.current == ws(1))
        #expect(requests(effects).map(\.purpose) == [.restore])
        #expect(effects.contains(.hud(workspace: ws(1), windowCount: 1)))
    }

    @Test func followFocusCanBeTurnedOff() {
        var (current, _) = parkedState()
        var config = EngineConfig()
        config.followFocus = false
        (current, _) = EngineReducer.reduce(current, .configChanged(config))
        let (next, effects) = EngineReducer.reduce(current, .windowFocused(id(1), now: 1_005))
        #expect(next.model.current == ws(2))
        #expect(requests(effects).isEmpty)
    }

    @Test func aFocusedParkedWindowThatMovesByItselfFollowsFocus() {
        var (current, _) = parkedState()
        current.focused = id(1)
        let (next, effects) = EngineReducer.reduce(
            current, .windowMoved(id(1), frame: CGRect(x: 300, y: 300, width: 800, height: 600), now: 1_010))
        #expect(next.model.current == ws(1))
        #expect(requests(effects).map(\.purpose) == [.restore])
    }

    // MARK: Generations

    @Test func aStaleResultIsIgnored() {
        var current = state([makeWindow(1)])
        var effects: [EngineEffect]
        (current, effects) = command(current, .showWorkspace(ws(2)))
        let park = requests(effects)[0]
        (current, effects) = command(current, .backAndForth)
        let restore = requests(effects)[0]
        #expect(restore.generation > park.generation)

        // The park result arrives after the restore was asked for: it must not change anything.
        let before = current
        (current, effects) = EngineReducer.reduce(current, .applied(succeed([park]), now: 1_001))
        #expect(current == before)
        #expect(effects.isEmpty)
    }

    @Test func aBatchGetsOneGenerationAndTheNextBatchTheNext() {
        let start = state([makeWindow(1), makeWindow(2, pid: 200)])
        var (current, effects) = command(start, .showWorkspace(ws(2)))
        #expect(Set(requests(effects).map(\.generation)) == [1])
        (current, effects) = command(current, .backAndForth)
        #expect(Set(requests(effects).map(\.generation)) == [2])
        #expect(current.generation == 2)
    }

    // MARK: Failures, stubborn windows

    @Test func aWindowThatRefusesItsSizeIsCentredOnceAndNeverRetried() {
        var current = state([makeWindow(1)])
        var effects: [EngineEffect]
        let tile = CGRect(x: 0, y: 25, width: 400, height: 300)
        (current, effects) = EngineReducer.reduce(current, .place(id(1), tile, now: 1_000))
        let request = requests(effects)[0]
        #expect(request.purpose == .place)

        // The window cannot be smaller than 600 x 500.
        let actual = CGRect(x: 0, y: 25, width: 600, height: 500)
        (current, effects) = EngineReducer.reduce(
            current, .applied([FrameResult(request: request, outcome: .applied(actual))], now: 1_000.1))
        #expect(current.stubborn == [id(1)])
        #expect(current.diagnostics.stubbornWindows == 1)
        let centring = requests(effects)
        #expect(centring.count == 1)
        #expect(centring[0].purpose == .place)
        #expect(centring[0].frame.size == actual.size)
        #expect(abs(centring[0].frame.midX - tile.midX) <= 100)

        // Its result also differs from the tile, and nothing more is asked.
        (current, effects) = EngineReducer.reduce(
            current, .applied([FrameResult(request: centring[0], outcome: .applied(centring[0].frame))], now: 1_000.2))
        #expect(requests(effects).isEmpty)
        #expect(current.diagnostics.stubbornWindows == 1)

        // A later placement of a stubborn window centres it at its own size.
        (current, effects) = EngineReducer.reduce(current, .place(id(1), tile, now: 1_001))
        #expect(requests(effects)[0].frame.size == actual.size)
    }

    @Test func aHungAppIsCountedAndItsFailedParkLeavesItJournalFree() {
        var current = state([makeWindow(1)])
        var effects: [EngineEffect]
        (current, effects) = command(current, .showWorkspace(ws(2)))
        let request = requests(effects)[0]
        (current, effects) = EngineReducer.reduce(
            current, .applied([FrameResult(request: request, outcome: .failed(.timedOut))], now: 1_001))
        #expect(current.diagnostics.accessibilityTimeouts == 1)
        #expect(current.parked.isEmpty)
        #expect(effects.contains(.journalRemove([id(1)])))
        #expect(current.windows[id(1)]?.frame == CGRect(x: 100, y: 100, width: 800, height: 600))
    }

    @Test func aFailedRestoreKeepsTheWindowParkedAndJournaled() {
        var (current, _) = parkedState()
        var effects: [EngineEffect]
        (current, effects) = command(current, .backAndForth)
        let request = requests(effects)[0]
        (current, effects) = EngineReducer.reduce(
            current, .applied([FrameResult(request: request, outcome: .failed(.refused))], now: 1_001))
        #expect(current.parked.keys.sorted() == [id(1)])
        #expect(!effects.contains { if case .journalRemove = $0 { true } else { false } })
    }

    @Test func aWindowThatIsGoneWhenParkedIsForgotten() {
        var current = state([makeWindow(1)])
        var effects: [EngineEffect]
        (current, effects) = command(current, .showWorkspace(ws(2)))
        let request = requests(effects)[0]
        (current, _) = EngineReducer.reduce(
            current, .applied([FrameResult(request: request, outcome: .failed(.windowGone))], now: 1_001))
        #expect(current.windows.isEmpty)
        #expect(current.model.workspace(of: id(1)) == nil)
    }

    @Test func aParkedWindowThatClosesIsRemovedFromTheJournal() {
        let (current, _) = parkedState()
        let (next, effects) = EngineReducer.reduce(current, .windowGone(id(1), now: 1_002))
        #expect(effects.contains(.journalRemove([id(1)])))
        #expect(next.parked.isEmpty)
    }

    // MARK: Watchdog, displays

    @Test func theWatchdogRestoresEverythingFreezesAndCounts() {
        var (current, _) = parkedState()
        var effects: [EngineEffect]
        (current, effects) = EngineReducer.reduce(current, .watchdogTripped(now: 1_100))
        #expect(current.isFrozen)
        #expect(current.diagnostics.watchdogTrips == 1)
        #expect(effects.contains(.banner(.watchdogTripped)))
        #expect(requests(effects).map(\.purpose) == [.restore])

        // Frozen: a window that moves is not hidden again and a re-hide is not tried.
        (current, effects) = EngineReducer.reduce(current, .applied(succeed(requests(effects)), now: 1_101))
        (current, effects) = EngineReducer.reduce(
            current, .windowMoved(id(1), frame: CGRect(x: 1, y: 1, width: 800, height: 600), now: 1_200))
        #expect(requests(effects).isEmpty)

        // A workspace command unfreezes.
        (current, _) = command(current, .showWorkspace(ws(3)), now: 1_300)
        #expect(!current.isFrozen)
    }

    @Test func restoreAllPutsEverythingBackAndStaysStill() {
        var (current, _) = parkedState()
        let (next, effects) = command(current, .restoreAll)
        #expect(requests(effects).map(\.purpose) == [.restore])
        #expect(next.isFrozen)
        current = next
        let (_, again) = EngineReducer.reduce(
            current, .windowAppeared(makeWindow(7, pid: 700), processStart: 1_700, now: 1_100))
        #expect(requests(again).isEmpty)
    }

    @Test func removingADisplayHidesItsWorkspaceAndAddingOneShowsAnother() {
        var current = state([makeWindow(1)], displays: [main, second])
        var effects: [EngineEffect]
        (current, effects) = EngineReducer.reduce(
            current,
            .windowAppeared(
                makeWindow(2, pid: 200, frame: CGRect(x: 2_000, y: 100, width: 800, height: 600)), processStart: 1_200,
                now: t0))
        #expect(current.model.workspace(of: id(2, pid: 200)) == ws(2))

        (current, effects) = EngineReducer.reduce(current, .displaysChanged([main], now: 1_100))
        #expect(!current.model.isVisible(ws(2)))
        let parks = requests(effects)
        #expect(parks.map(\.id) == [id(2, pid: 200)])
        // Parked in the corner of the display that remains (the window's own display is gone).
        #expect(parks[0].frame.origin == CGPoint(x: 1919, y: 1079))

        (current, effects) = EngineReducer.reduce(current, .applied(succeed(parks), now: 1_101))
        (current, effects) = EngineReducer.reduce(current, .displaysChanged([main, second], now: 1_200))
        #expect(current.model.isVisible(ws(2)))
        #expect(requests(effects).map(\.purpose) == [.restore])
    }

    @Test func aResolutionChangeRepartksParkedWindowsInTheNewCorner() {
        var (current, _) = parkedState()
        let smaller = DisplayInfo(
            id: 1, uuid: "MAIN", frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
            visibleFrame: CGRect(x: 0, y: 25, width: 1280, height: 695), isMain: true)
        let effects: [EngineEffect]
        (current, effects) = EngineReducer.reduce(current, .displaysChanged([smaller], now: 1_100))
        let parks = requests(effects)
        #expect(parks.count == 1)
        #expect(parks[0].frame.origin == CGPoint(x: 1279, y: 719))
        #expect(!effects.contains { if case .journalPark = $0 { true } else { false } })
    }

    @Test func restoredFramesAreClampedToAConnectedDisplay() {
        let far = CGRect(x: 5_000, y: 100, width: 800, height: 600)
        var current = state([makeWindow(1, frame: far)], displays: [main])
        var effects: [EngineEffect]
        (current, effects) = command(current, .showWorkspace(ws(2)))
        (current, _) = EngineReducer.reduce(current, .applied(succeed(requests(effects)), now: 1_000))
        (current, effects) = command(current, .backAndForth)
        let restore = requests(effects)[0]
        #expect(main.visibleFrame.contains(restore.frame))
        #expect(restore.frame.size == far.size)
    }

    @Test func theConfigCanListMoreFloatingApps() {
        var current = state([makeWindow(1, bundleID: "com.example.app")])
        var config = EngineConfig()
        config.floatingBundleIDs = ["com.example.app"]
        (current, _) = EngineReducer.reduce(current, .configChanged(config))
        (current, _) = EngineReducer.reduce(
            current, .windowAppeared(makeWindow(2, bundleID: "com.example.app"), processStart: 1_100, now: t0))
        // The window that is already managed stays until the next snapshot; a new one is not taken.
        #expect(current.windows[id(2)] == nil)
    }

    @Test func titlesAndBundleIDsNeverReachTheEffects() {
        let start = state([makeWindow(1)])
        let (_, effects) = command(start, .showWorkspace(ws(2)))
        #expect(!String(describing: effects).contains("secret title"))
        #expect(!String(describing: effects).contains("com.example.app"))
    }
}
