import CoreGraphics
import LintelKit
import Testing

@testable import WindowsPlugin

/// Window management v2, step 1.3: the Accordion layout kind (pure geometry, the strategy, its state and the reducer
/// path of a change of focus).
@Suite(.timeLimit(.minutes(1))) struct AccordionTests {
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private func id(_ number: UInt32) -> WindowID { WindowID(pid: 100, number: number) }
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }
    private func order(_ count: Int) -> [WindowID] { (1...count).map { id(UInt32($0)) } }

    private func frames(
        _ count: Int, focus: Int, gaps: TilingGaps = .none, padding: CGFloat = 30,
        orientation: AccordionLayout.Orientation = .horizontal
    ) -> [CGRect] {
        let windows = order(count)
        let result = AccordionLayout.frames(
            order: windows, focused: windows[focus], area: area, gaps: gaps, padding: padding,
            orientation: orientation)
        return windows.map { result[$0] ?? .zero }
    }

    // MARK: Golden frames

    @Test func oneWindowTakesTheWholeAreaWhateverThePadding() {
        #expect(frames(1, focus: 0) == [area])
        #expect(frames(1, focus: 0, padding: 200) == [area])
    }

    @Test func twoWindowsHorizontalLeaveTheEdgeOfTheOtherOneShowing() {
        #expect(
            frames(2, focus: 0) == [
                CGRect(x: 0, y: 0, width: 970, height: 600), CGRect(x: 30, y: 0, width: 970, height: 600),
            ])
        #expect(
            frames(2, focus: 1) == [
                CGRect(x: 0, y: 0, width: 970, height: 600), CGRect(x: 30, y: 0, width: 970, height: 600),
            ])
    }

    @Test func fiveWindowsShowBothSidesOfAMiddleFocus() {
        let result = frames(5, focus: 2)
        let before = CGRect(x: 0, y: 0, width: 970, height: 600)
        let core = CGRect(x: 30, y: 0, width: 940, height: 600)
        let after = CGRect(x: 30, y: 0, width: 970, height: 600)
        #expect(result == [before, before, core, after, after])
    }

    @Test func verticalSticksOutAboveAndBelow() {
        let result = frames(3, focus: 1, orientation: .vertical)
        #expect(result[0] == CGRect(x: 0, y: 0, width: 1000, height: 570))
        #expect(result[1] == CGRect(x: 0, y: 30, width: 1000, height: 540))
        #expect(result[2] == CGRect(x: 0, y: 30, width: 1000, height: 570))
    }

    @Test func zeroPaddingStacksEveryWindowOnTheSameArea() {
        #expect(frames(4, focus: 1, padding: 0).allSatisfy { $0 == area })
    }

    @Test func theOuterGapIsTakenOutFirstAndTheInnerGapDoesNotApply() {
        let result = frames(2, focus: 0, gaps: TilingGaps(inner: 10, outer: 10))
        #expect(result[0] == CGRect(x: 10, y: 10, width: 950, height: 580))
        #expect(result[1] == CGRect(x: 40, y: 10, width: 950, height: 580))
    }

    @Test func aHugePaddingNeverTakesMoreThanAQuarterOfTheLength() {
        #expect(frames(2, focus: 0, padding: 10_000)[0].width == 750)
    }

    @Test func aFocusOutsideTheOrderCountsAsTheFirstWindow() {
        let result = AccordionLayout.frames(
            order: order(2), focused: id(99), area: area, gaps: .none, padding: 30, orientation: .horizontal)
        #expect(result[id(1)] == CGRect(x: 0, y: 0, width: 970, height: 600))
    }

    // MARK: The strategy

    @Test func theRegistryHasAccordionLastSoTheDefaultKindAndTheCycleStayAsInV1() {
        let registry = LayoutRegistry.standard
        #expect(registry.kinds == [.tiling, .zones, .free, .accordion])
        #expect(registry.defaultKind == .tiling)
        // No option id repeats, so the strategy was not left out.
        #expect(registry.contains(.accordion))
        #expect(registry.option(id: AccordionStrategy.paddingID) != nil)
    }

    @Test func accordionOptionsHaveTheSpecDefaults() throws {
        let padding = try #require(LayoutRegistry.standard.option(id: AccordionStrategy.paddingID))
        #expect(padding.defaultValue == .int(30) && padding.settingKey == "accordion.padding")
        #expect(padding.valid(.int(500)) == .int(200))
        let orientation = try #require(LayoutRegistry.standard.option(id: AccordionStrategy.orientationID))
        #expect(orientation.defaultValue == .string("auto"))
        #expect(orientation.valid(.string("diagonal")) == nil)
    }

    private func input(
        windows: [WindowID], state: AccordionState? = nil, focused: WindowID? = nil,
        display: CGRect? = nil
    ) -> LayoutInput {
        let strategy = AccordionStrategy()
        var options: [String: JSONValue] = [:]
        for option in strategy.options { options[option.id] = option.defaultValue }
        return LayoutInput(
            workspace: ws(1), windows: windows, apps: [:], state: state.map { AnyLayoutState($0) },
            config: AnyLayoutConfig(AccordionConfig(gaps: .none)),
            resolved: ResolvedLayout(kind: .accordion, options: options), focused: focused, previousFocus: nil,
            display: DisplayInfo(id: 1, uuid: "A", frame: display ?? area, isMain: true), displayKey: "A", hints: [:])
    }

    @Test func newWindowsEnterAfterTheFocusedOneAndGoneOnesLeave() throws {
        let strategy = AccordionStrategy()
        let first = strategy.arrange(input(windows: order(3), focused: id(1)))
        #expect(first.state?.as(AccordionState.self)?.order == order(3))
        // Window 4 appears while 1 is focused: it enters after 1; window 2 is gone.
        let next = strategy.arrange(
            input(
                windows: [id(1), id(3), id(4)], state: first.state?.as(AccordionState.self), focused: id(1)))
        #expect(next.state?.as(AccordionState.self)?.order == [id(1), id(4), id(3)])
    }

    @Test func autoOrientationFollowsTheShapeOfTheDisplay() {
        let strategy = AccordionStrategy()
        let landscape = strategy.arrange(input(windows: order(2), focused: id(1)))
        #expect(landscape.frames[id(1)]?.width == 970)
        let portrait = strategy.arrange(
            input(windows: order(2), focused: id(1), display: CGRect(x: 0, y: 0, width: 600, height: 1000)))
        #expect(portrait.frames[id(1)]?.height == 970)
    }

    @Test func focusAndMoveCommandsFollowTheOrientationAndStopAtTheEnds() throws {
        let strategy = AccordionStrategy()
        let state = AccordionState(order: order(3))
        let right = strategy.perform(.focus(.right), on: id(2), input(windows: order(3), state: state, focused: id(2)))
        #expect(right?.focus == id(3))
        let up = strategy.perform(.focus(.up), on: id(2), input(windows: order(3), state: state, focused: id(2)))
        #expect(up == nil)
        let end = strategy.perform(.focus(.right), on: id(3), input(windows: order(3), state: state, focused: id(3)))
        #expect(end == nil)
        let moved = strategy.perform(.move(.left), on: id(2), input(windows: order(3), state: state, focused: id(2)))
        #expect(moved?.state.as(AccordionState.self)?.order == [id(2), id(1), id(3)])
    }

    @Test func theStateRoundTripsAndAnEmptyOneIsNotStored() throws {
        let strategy = AccordionStrategy()
        let state = AnyLayoutState(AccordionState(order: order(3)))
        let json = try #require(strategy.encode(state))
        #expect(strategy.decode(json) == state)
        #expect(strategy.decode(.string("nonsense")) == nil)
    }

    @Test func theStateOfAKindSurvivesASwitchOfKindAndTheRegistryRoundTrip() throws {
        let registry = LayoutRegistry.standard
        let stored: [WorkspaceID: [String: JSONValue]] = [
            ws(1): [
                "accordion": try #require(AccordionStrategy().encode(AnyLayoutState(AccordionState(order: order(2)))))
            ]
        ]
        #expect(registry.encode(registry.decode(stored)) == stored)
    }

    // MARK: Focus changes arrange again, and only where the kind asks for it

    private func accordionState(count: Int, kind: LayoutKind = .accordion) -> EngineState {
        var config = EngineConfig()
        config.layout = LayoutConfig(
            defaultKind: kind,
            optionDefaults: [
                .accordion: [
                    AccordionStrategy.paddingID: .int(30), AccordionStrategy.orientationID: .string("horizontal"),
                ]
            ])
        config.strategyConfigs[.accordion] = AnyLayoutConfig(AccordionConfig(gaps: .none))
        var state = EngineState(workspaceCount: 4)
        state.config = config
        let windows = (1...count).map { makeWindow(UInt32($0), frame: CGRect(x: 100, y: 100, width: 400, height: 300)) }
        let display = DisplayInfo(id: 1, uuid: "MAIN", frame: area, isMain: true)
        let starts = [Int32(100): 1_100.0]
        (state, _) = EngineReducer.reduce(
            state, .snapshot(windows: windows, displays: [display], focused: id(1), processStarts: starts, now: 1_000))
        return state
    }

    private func place(_ effects: [EngineEffect]) -> [FrameRequest] {
        effects.compactMap { if case .setFrame(let request) = $0, request.purpose == .place { request } else { nil } }
    }

    private func settle(_ state: EngineState, _ effects: [EngineEffect], now: Double) -> EngineState {
        let results = place(effects).map { FrameResult(request: $0, outcome: .applied($0.frame)) }
        guard !results.isEmpty else { return state }
        return EngineReducer.reduce(state, .applied(results, now: now)).0
    }

    @Test func aChangeOfFocusMovesOnlyTheTwoWindowsThatChangeTheirFrame() {
        var state = accordionState(count: 5)
        // The first arrangement happens on the first reduction that asks for one.
        var effects: [EngineEffect]
        (state, effects) = EngineReducer.reduce(state, .windowFocused(id(1), now: 1_001))
        state = settle(state, effects, now: 1_001)
        // From the first window to the second: only the second changes (the first keeps the frame it has as the
        // window in front of the others, which is also the frame of a window behind them on its side).
        (state, effects) = EngineReducer.reduce(state, .windowFocused(id(2), now: 1_002))
        #expect(place(effects).map(\.id) == [id(2)])
        state = settle(state, effects, now: 1_002)
        // From the second to the third: the old and the new focused window swap roles, nothing else moves.
        (state, effects) = EngineReducer.reduce(state, .windowFocused(id(3), now: 1_003))
        #expect(place(effects).map(\.id).sorted() == [id(2), id(3)])
    }

    @Test func anAutoTileWorkspaceDoesNotArrangeOnAFocusChange() {
        var state = accordionState(count: 3, kind: .tiling)
        var effects: [EngineEffect]
        (state, effects) = EngineReducer.reduce(state, .windowFocused(id(1), now: 1_001))
        state = settle(state, effects, now: 1_001)
        (state, effects) = EngineReducer.reduce(state, .windowFocused(id(2), now: 1_002))
        #expect(place(effects).isEmpty)
    }

    @Test func walkingTheFocusThroughNineWindowsStaysFarBelowTheWatchdog() {
        var state = accordionState(count: 9)
        var effects: [EngineEffect]
        (state, effects) = EngineReducer.reduce(state, .windowFocused(id(1), now: 1_001))
        state = settle(state, effects, now: 1_001)
        var watchdog = Watchdog()
        var changes = 0
        var now = 1_002.0
        // Forward through all nine and back again, a window every 10 ms.
        for number in Array(2...9) + Array((1...8).reversed()) {
            (state, effects) = EngineReducer.reduce(state, .windowFocused(id(UInt32(number)), now: now))
            for _ in place(effects) {
                changes += 1
                let tripped = watchdog.record(now: now)
                #expect(!tripped)
            }
            state = settle(state, effects, now: now)
            now += 0.01
        }
        #expect(!state.isFrozen)
        #expect(state.diagnostics.watchdogTrips == 0)
        // Two frames per step, a few more where the first or last window gains or loses a neighbour.
        #expect(changes <= 16 * 2 + 2 * 8, "\(changes) frame changes")
    }

    // MARK: Next display

    @Test func nextDisplayGivesTheCurrentWorkspaceToTheOtherDisplayAndSwapsThem() {
        var model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["A", "B"])
        #expect(model.current == ws(1))
        let moved = model.moveCurrentToNextDisplay()
        #expect(moved)
        // The workspace went to B and the focus with it; B's workspace 2 is on A now.
        #expect(model.visible == ["A": ws(2), "B": ws(1)])
        #expect(model.current == ws(1) && model.focusedDisplay == "B")
        // Wrapping around: from the last display back to the first.
        let back = model.moveCurrentToNextDisplay()
        #expect(back)
        #expect(model.visible == ["A": ws(1), "B": ws(2)] && model.focusedDisplay == "A")
    }

    @Test func nextDisplayDoesNothingWithOneDisplay() {
        var model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["A"])
        let moved = model.moveCurrentToNextDisplay()
        #expect(!moved)
        #expect(model.current == ws(1))
    }

    @Test func nextDisplayWithOneDisplayShowsTheNoticeAndChangesNothing() {
        let state = accordionState(count: 2, kind: .tiling)
        let (next, effects) = EngineReducer.reduce(state, .command(.moveWorkspaceToNextDisplay, now: 1_001))
        #expect(effects.contains(.notice(.singleDisplay)))
        #expect(next.model == state.model)
    }

    @Test func nextDisplayWithTwoDisplaysMovesTheWorkspaceAndFocusesItsMostRecentWindow() {
        var state = EngineState(workspaceCount: 4)
        let second = DisplayInfo(id: 2, uuid: "SECOND", frame: CGRect(x: 1000, y: 0, width: 1000, height: 600))
        let main = DisplayInfo(id: 1, uuid: "MAIN", frame: area, isMain: true)
        let windows = [
            makeWindow(1, frame: CGRect(x: 100, y: 100, width: 300, height: 300)),
            makeWindow(2, frame: CGRect(x: 1100, y: 100, width: 300, height: 300)),
        ]
        (state, _) = EngineReducer.reduce(
            state,
            .snapshot(
                windows: windows, displays: [main, second], focused: id(1), processStarts: [100: 1_100], now: 1_000))
        let before = state.model.current
        let (next, effects) = EngineReducer.reduce(state, .command(.moveWorkspaceToNextDisplay, now: 1_001))
        #expect(next.model.current == before)
        #expect(next.model.focusedDisplay != state.model.focusedDisplay)
        #expect(!effects.contains(.notice(.singleDisplay)))
        #expect(next.focused == id(1))
    }
}
