import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// Phase 0 of window management v2: the shortcut "move the focused window" must act on the window the user sees
/// focused, never on one that a workspace switch has just parked. The reducer is exercised on plain values; the
/// runtime part (the focus read at the moment of the command) is in `FocusReadTests`.
@Suite(.timeLimit(.minutes(1))) struct FocusHandoffTests {
    private let main = FakeWindowClient.mainDisplay
    private let t0 = 1_000.0
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }
    private func id(_ number: UInt32, pid: Int32 = 100) -> WindowID { WindowID(pid: pid, number: number) }

    /// Workspace 1 with the given windows (all of one process), nothing focused yet.
    private func state(_ numbers: [UInt32], count: Int = 4) -> EngineState {
        let windows = numbers.map { makeWindow($0) }
        let (next, _) = EngineReducer.reduce(
            EngineState(workspaceCount: count),
            .snapshot(windows: windows, displays: [main], focused: nil, processStarts: [100: 1_100], now: t0))
        return next
    }

    private func reduce(_ state: EngineState, _ input: EngineInput) -> (EngineState, [EngineEffect]) {
        EngineReducer.reduce(state, input)
    }

    private func command(_ state: EngineState, _ command: EngineCommand) -> (EngineState, [EngineEffect]) {
        reduce(state, .command(command, now: t0))
    }

    private func focus(_ state: EngineState, _ window: WindowID?) -> EngineState {
        reduce(state, .windowFocused(window, now: t0)).0
    }

    private func requests(_ effects: [EngineEffect]) -> [FrameRequest] {
        effects.compactMap { if case .setFrame(let request) = $0 { request } else { nil } }
    }

    private func focusTargets(_ effects: [EngineEffect]) -> [WindowID] {
        effects.compactMap { if case .focus(let id) = $0 { id } else { nil } }
    }

    // MARK: Step 0.1 (a): the window a switch just parked is not moved

    @Test func movingRightAfterASwitchDoesNotMoveTheWindowThatWasJustParked() {
        var current = focus(state([1, 2]), id(1))
        (current, _) = command(current, .showWorkspace(ws(2)))
        #expect(current.parked.keys.sorted() == [id(1), id(2)])
        let (next, effects) = command(current, .moveFocusedWindow(to: ws(3)))
        #expect(next.model.workspace(of: id(1)) == ws(1))
        #expect(next.model.workspace(of: id(2)) == ws(1))
        #expect(requests(effects).isEmpty)
        #expect(effects.contains(.notice(.noFocusedWindow)))
    }

    @Test func aParkedFocusIsNeverMovedEvenWhenTheEngineStillNamesIt() {
        // The focus names a window of a hidden workspace (an event the switch did not clear).
        var current = focus(state([1, 2]), id(1))
        (current, _) = command(current, .showWorkspace(ws(2)))
        current.focused = id(1)
        let (next, effects) = command(current, .moveFocusedWindow(to: ws(3)))
        #expect(next.model.workspace(of: id(1)) == ws(1))
        #expect(requests(effects).isEmpty)
        #expect(effects.contains(.notice(.noFocusedWindow)))
    }

    @Test func floatingIsNotToggledOnAWindowThatAParkedFocusStillNames() {
        // Workspace 2 is empty, so nothing takes the focus; the system still names the window the switch parked.
        var current = focus(state([1, 2]), id(1))
        (current, _) = command(current, .showWorkspace(ws(2)))
        (current, _) = reduce(current, .focusObserved(id(1), now: t0 + 2))
        #expect(current.focused == id(1))
        let (next, effects) = command(current, .toggleFloating)
        #expect(next.floating.isEmpty)
        #expect(effects.contains(.notice(.noFocusedWindow)))
        // A window the user can see is still toggled.
        var shown = focus(state([1, 2]), id(1))
        (shown, _) = command(shown, .toggleFloating)
        #expect(shown.floating == [id(1)])
    }

    // MARK: Step 0.2: most recently used window per workspace

    nonisolated struct Handoff: Sendable, CustomTestStringConvertible {
        var name: String
        var windows: [UInt32]
        /// The windows focused one after the other, the last one is focused now.
        var focusSequence: [UInt32]
        var target: Int
        var back: Bool
        var expected: UInt32?
        var testDescription: String { name }
    }

    @Test(
        arguments: [
            Handoff(
                name: "empty workspace", windows: [1, 2], focusSequence: [1], target: 2, back: false, expected: nil),
            Handoff(name: "one window", windows: [1], focusSequence: [1], target: 1, back: false, expected: 1),
            Handoff(
                name: "several windows, last used wins", windows: [1, 2, 3], focusSequence: [3, 1, 2], target: 1,
                back: false, expected: 2),
            Handoff(
                name: "coming back with option-tab", windows: [1, 2, 3], focusSequence: [2, 3, 1], target: 2,
                back: true, expected: 1),
        ])
    func aSwitchGivesTheFocusToTheMostRecentlyUsedWindow(_ row: Handoff) {
        var current = state(row.windows)
        for number in row.focusSequence { current = focus(current, id(number)) }
        var effects: [EngineEffect]
        if row.back {
            (current, _) = command(current, .showWorkspace(ws(row.target)))
            #expect(current.focused == nil)
            (current, effects) = command(current, .backAndForth)
        } else {
            (current, effects) = command(current, .showWorkspace(ws(row.target)))
        }
        #expect(current.focused == row.expected.map { id($0) })
        #expect(focusTargets(effects) == (row.back ? row.expected.map { [id($0)] } ?? [] : []))
    }

    @Test func switchingAwayAndBackHandsTheFocusToTheLastUsedWindowAndAsksTheSystemForIt() {
        var current = state([1, 2, 3])
        for number: UInt32 in [3, 1, 2] { current = focus(current, id(number)) }
        (current, _) = command(current, .showWorkspace(ws(2)))
        let (next, effects) = command(current, .showWorkspace(ws(1)))
        #expect(next.focused == id(2))
        #expect(focusTargets(effects) == [id(2)])
    }

    @Test func aColdStartWithNoHistoryFallsBackToTheWorkspaceOrder() {
        var current = state([1, 2, 3])
        (current, _) = command(current, .showWorkspace(ws(2)))
        let (next, effects) = command(current, .showWorkspace(ws(1)))
        #expect(next.focused == id(3))
        #expect(focusTargets(effects) == [id(3)])
    }

    // MARK: Step 0.1 (c) and 0.4: after a move the focus goes to the window used last

    @Test func afterAMoveTheFocusGoesToTheMostRecentlyUsedWindowOfTheSourceWorkspace() {
        // Order of the workspace: 1, 2, 3. Used: 3, then 1, then 2 (2 is focused and moves away).
        var current = state([1, 2, 3])
        for number: UInt32 in [3, 1, 2] { current = focus(current, id(number)) }
        let (next, effects) = command(current, .moveFocusedWindow(to: ws(3)))
        #expect(next.model.workspace(of: id(2)) == ws(3))
        #expect(focusTargets(effects) == [id(1)])
        #expect(next.focused == id(1))
    }

    @Test func movingTheOnlyWindowLeavesNothingFocusedInsteadOfAParkedWindow() {
        var current = focus(state([1]), id(1))
        (current, _) = command(current, .moveFocusedWindow(to: ws(3)))
        #expect(current.focused == nil)
        let (next, effects) = command(current, .moveFocusedWindow(to: ws(4)))
        #expect(next.model.workspace(of: id(1)) == ws(3))
        #expect(requests(effects).isEmpty)
        #expect(effects.contains(.notice(.noFocusedWindow)))
    }

    @Test func aMovedWindowKeepsItsPlaceInTheRecencyOfItsNewWorkspace() {
        var current = state([1, 2])
        for number: UInt32 in [1, 2] { current = focus(current, id(number)) }
        (current, _) = command(current, .moveFocusedWindow(to: ws(3)))
        (current, _) = command(current, .showWorkspace(ws(3)))
        #expect(current.focused == id(2))
    }

    // MARK: Step 0.3: what the system says at the moment of the command

    @Test func anObservationThatDiffersFromTheEventsWinsAndIsCounted() {
        var current = focus(state([1, 2]), id(1))
        (current, _) = reduce(current, .focusObserved(id(2), now: t0))
        #expect(current.focused == id(2))
        #expect(current.diagnostics.focusMismatches == 1)
        (current, _) = reduce(current, .focusObserved(id(2), now: t0))
        #expect(current.diagnostics.focusMismatches == 1)
    }

    @Test func anObservationNeverSwitchesWorkspace() {
        var current = focus(state([1, 2]), id(1))
        (current, _) = command(current, .showWorkspace(ws(2)))
        let (next, effects) = reduce(current, .focusObserved(id(1), now: t0))
        #expect(next.model.current == ws(2))
        #expect(requests(effects).isEmpty)
    }

    @Test func aPendingFocusWinsOverAnObservationOfAParkedWindowAndExpiresAfterOneSecond() {
        var current = state([1, 2])
        current = focus(current, id(1))
        (current, _) = command(current, .moveFocusedWindow(to: ws(2)))
        current = focus(current, id(2))
        // Workspace 2 holds 1; go there: the engine asks the system to focus 1.
        (current, _) = command(current, .showWorkspace(ws(2)))
        #expect(current.focused == id(1))
        #expect(current.pendingFocus?.id == id(1))
        // The system still says 2 (parked): the request wins.
        var (next, _) = reduce(current, .focusObserved(id(2), now: t0 + 0.5))
        #expect(next.focused == id(1))
        #expect(next.diagnostics.focusMismatches == 0)
        // After a second the request is over and the observation is believed.
        (next, _) = reduce(current, .focusObserved(id(2), now: t0 + 1.5))
        #expect(next.pendingFocus == nil)
        #expect(next.focused == id(2))
        // A confirming focus event ends the request at once.
        (next, _) = reduce(current, .windowFocused(id(1), now: t0 + 0.1))
        #expect(next.pendingFocus == nil)
    }

    @Test func anObservationOfAnUnmanagedWindowClearsTheFocusAndFocusLeftStaysTolerant() {
        var current = focus(state([1, 2]), id(1))
        let finder = id(9, pid: 400)
        (current, _) = reduce(current, .focusObserved(finder, now: t0))
        #expect(current.focused == nil)
        #expect(current.previousFocus == id(1))
        // Moving is refused, with the HUD.
        let (_, effects) = command(current, .moveFocusedWindow(to: ws(2)))
        #expect(effects.contains(.notice(.noFocusedWindow)))
        let (_, floatEffects) = command(current, .toggleFloating)
        #expect(floatEffects.contains(.notice(.noFocusedWindow)))
        // A focus command counts from the last managed window and shows no refusal.
        let (_, focusEffects) = command(current, .focusDirection(.right))
        #expect(!focusEffects.contains(.notice(.noFocusedWindow)))
    }

    @Test func aReadThatTimedOutIsCounted() {
        let (next, _) = reduce(EngineState(), .focusReadTimedOut(now: t0))
        #expect(next.diagnostics.focusReadTimeouts == 1)
    }

    @Test func commandsThatActOnTheFocusedWindowAreTheOnesThatReadTheFocus() {
        #expect(EngineCommand.moveFocusedWindow(to: ws(2)).readsFocus)
        #expect(EngineCommand.toggleFloating.readsFocus)
        #expect(EngineCommand.focusDirection(.left).readsFocus)
        #expect(!EngineCommand.showWorkspace(ws(2)).readsFocus)
        #expect(!EngineCommand.layout(.focus(.left), on: id(1)).readsFocus)
        #expect(EngineCommand.moveDirection(.left).needsFocusedWindow)
        #expect(!EngineCommand.focusDirection(.left).needsFocusedWindow)
    }

    // MARK: Empty source workspace: system focus must not stay on a parked window (QA D1)

    private let second = FakeWindowClient.secondDisplay

    /// Windows 1 and 2 on workspace 1 (display 1); window 2 then goes to workspace 2, which the second display shows.
    private func twoDisplays() -> EngineState {
        var current = EngineReducer.reduce(
            EngineState(workspaceCount: 4),
            .snapshot(
                windows: [makeWindow(1), makeWindow(2)], displays: [main, second], focused: nil,
                processStarts: [100: 1_100], now: t0)
        ).0
        current = focus(current, id(2))
        (current, _) = command(current, .moveFocusedWindow(to: ws(2)))
        return focus(current, id(1))
    }

    @Test func movingTheLastWindowOfAWorkspaceFocusesAVisibleWindowOnAnotherDisplay() {
        let start = twoDisplays()
        #expect(start.model.windows(in: ws(1)) == [id(1)])
        let (next, effects) = command(start, .moveFocusedWindow(to: ws(3)))
        #expect(next.parked.keys.sorted() == [id(1)])
        #expect(focusTargets(effects) == [id(2)])
        #expect(next.focused == id(2))
    }

    @Test func movingTheLastWindowOnASingleDisplayClearsTheFocusAndAsksForNoParkedWindow() {
        var current = focus(state([1]), id(1))
        let effects: [EngineEffect]
        (current, effects) = command(current, .moveFocusedWindow(to: ws(3)))
        #expect(current.focused == nil)
        #expect(focusTargets(effects).isEmpty)
    }

    @Test func movingWithNoRecencyHistoryFocusesTheLastWindowInTileOrder() {
        // Nothing was ever focused, the engine only knows the observation of window 3.
        var current = state([1, 2, 3])
        (current, _) = reduce(current, .focusObserved(id(3), now: t0))
        current.focusOrder = []
        let (next, effects) = command(current, .moveFocusedWindow(to: ws(4)))
        #expect(focusTargets(effects) == [id(2)])
        #expect(next.focused == id(2))
    }

    @Test func switchingToAnEmptyWorkspaceFocusesAVisibleWindowOfAnotherDisplay() {
        var current = twoDisplays()
        // Workspace 3 replaces the one on the display that holds window 1; window 2 stays visible on the other.
        (current, _) = command(current, .showWorkspace(ws(3)))
        #expect(current.model.isVisible(ws(2)))
        #expect(current.focused == id(2))
    }

    @Test func switchingToAWorkspaceWithoutRecencyFocusesItsLastWindowInOrder() {
        var current = state([1, 2], count: 3)
        (current, _) = command(current, .showWorkspace(ws(2)))
        current.focusOrder = []
        current.pendingFocus = nil
        current.focused = nil
        let (next, effects) = command(current, .showWorkspace(ws(1)))
        #expect(next.focused == id(2))
        #expect(focusTargets(effects) == [id(2)])
    }

    // MARK: Re-QA D1-3: a focus that was hidden and is revealed by the switch is not where the system focus is

    @Test func revealingTheWorkspaceOfAHiddenFocusStillAsksTheSystemToFocusAVisibleWindow() {
        // The system keeps the focus on window 1 while its workspace is hidden (a parked window keeps the app's
        // focus), so the engine believes window 1 is focused. Showing its workspace again must not take that belief
        // for the system's: the window gets an explicit focus request.
        var current = state([1, 2])
        for number: UInt32 in [1, 2] { current = focus(current, id(number)) }
        (current, _) = command(current, .showWorkspace(ws(2)))
        (current, _) = reduce(current, .focusObserved(id(1), now: t0))
        #expect(current.focused == id(1))
        let (next, effects) = command(current, .showWorkspace(ws(1)))
        #expect(focusTargets(effects) == [id(1)])
        #expect(next.focused == id(1))
    }

    @Test func aFocusThatWasAlreadyVisibleBeforeTheSwitchIsKept() {
        var current = twoDisplays()
        // Window 2 stays visible on the other display and keeps its focus through a switch on the first display.
        current = focus(current, id(2))
        let (next, effects) = command(current, .showWorkspace(ws(3)))
        #expect(focusTargets(effects).isEmpty)
        #expect(next.focused == id(2))
    }
}
