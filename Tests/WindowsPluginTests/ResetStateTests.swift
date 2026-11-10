import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// `EngineCommand.resetState` in the reducer: what is only remembered starts over, every window joins the workspace
/// shown on its display, and the journal side (`state.parked`) is left alone.
@Suite(.timeLimit(.minutes(1))) struct ResetStateTests {
    private let main = FakeWindowClient.mainDisplay
    private let second = FakeWindowClient.secondDisplay
    private func id(_ number: UInt32) -> WindowID { WindowID(pid: 100, number: number) }
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }

    /// Window 1 on the main display, 2 and 3 on the second one; the old membership puts 1 in workspace 3.
    private func prepared() -> EngineState {
        var state = EngineState(workspaceCount: 4, displays: [main, second])
        state.config.layout = LayoutConfig(defaultKind: .tiling)
        let windows = [
            makeWindow(1, frame: CGRect(x: 100, y: 100, width: 800, height: 600)),
            makeWindow(2, frame: CGRect(x: 2020, y: 100, width: 800, height: 600)),
            makeWindow(3, frame: CGRect(x: 2100, y: 200, width: 800, height: 600)),
        ]
        (state, _) = EngineReducer.reduce(
            state,
            .snapshot(
                windows: windows, displays: [main, second], focused: id(1), processStarts: [100: 1_100], now: 1))
        state.layouts[ws(1)] = ["tiling": AnyLayoutState(tree(.horizontal, [leaf(1), leaf(2)]))]
        state.placementHints = ["com.example.app": 2]
        state.previousFocus = id(2)
        state.isFrozen = false
        return state
    }

    @Test func layoutsHintsAndPreviousFocusStartOverAndBothStoredValuesAreWritten() {
        let state = prepared()
        let (after, effects) = EngineReducer.reduce(state, .command(.resetState, now: 5))
        // The old tree (windows 1 and 2 side by side in workspace 1) is gone; what is arranged now is the new membership.
        // The old tree is gone and nothing is arranged yet (the engine is frozen after the restore): exactly empty.
        #expect(after.layouts.isEmpty)
        // The membership is rebuilt by display: workspace 1 (main) holds window 1, workspace 2 (second) holds 2 and 3.
        #expect(after.model.order == [ws(1): [id(1)], ws(2): [id(2), id(3)]])
        #expect(after.placementHints.isEmpty)
        #expect(after.previousFocus == nil)
        // Written whether or not they changed: the caller has just cleared the file.
        #expect(effects.contains(.saveOrder(after.model.order)))
        #expect(effects.contains { if case .saveLayouts = $0 { true } else { false } })
    }

    @Test func everyWindowJoinsTheWorkspaceShownOnItsDisplay() {
        var state = prepared()
        // The old membership is scrambled: all three windows sit in workspace 3 (hidden).
        for number in 1...3 { state.model.move(id(UInt32(number)), to: ws(3)) }
        let (after, _) = EngineReducer.reduce(state, .command(.resetState, now: 5))
        let shownOnMain = after.model.visible[after.displayKey(of: main)]
        let shownOnSecond = after.model.visible[after.displayKey(of: second)]
        #expect(after.model.workspace(of: id(1)) == shownOnMain)
        #expect(after.model.workspace(of: id(2)) == shownOnSecond)
        #expect(after.model.workspace(of: id(3)) == shownOnSecond)
    }

    @Test func theEngineStaysFrozenAfterTheRestoreLikeRestoreAll() {
        let (after, _) = EngineReducer.reduce(prepared(), .command(.resetState, now: 5))
        #expect(after.isFrozen)
    }

    @Test func aWindowThatIsStillParkedGoesToItsHomeDisplayNotTheParkingCorner() {
        var state = prepared()
        // Window 3's home is on the MAIN display; it is parked in the corner of the union of all displays, which
        // lies on the second display, so reading its parked frame would give the wrong workspace.
        let home = CGRect(x: 100, y: 300, width: 800, height: 600)
        let corner = CGRect(x: 3839, y: 1079, width: 800, height: 600)
        state.windows[id(3)]?.frame = corner
        state.parked[id(3)] = ParkRecord(home: home, parkedFrame: corner, processStart: 1_100)
        let (after, _) = EngineReducer.reduce(state, .command(.resetState, now: 5))
        // A still-parked window keeps its parked record (the journal side); its workspace is its home display's.
        #expect(after.parked[id(3)] != nil)
        #expect(after.model.workspace(of: id(3)) == after.model.visible[after.displayKey(of: main)])
        #expect(after.model.workspace(of: id(3)) != after.model.visible[after.displayKey(of: second)])
    }
}
