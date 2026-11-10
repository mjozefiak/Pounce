import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// `EngineCommand.resetState` in the reducer: what is only remembered starts over, every window joins the workspace
/// shown on its display, and the journal side (`state.parked`) is left alone.
@Suite struct ResetStateTests {
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
        #expect(after.layouts[ws(1)]?["tiling"]?.as(TilingTree.self)?.windows != [id(1), id(2)])
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
        // Window 3 is parked in the corner of the union of all displays; its home is on the second display.
        let home = CGRect(x: 2100, y: 200, width: 800, height: 600)
        let corner = CGRect(x: 3839, y: 1079, width: 800, height: 600)
        state.windows[id(3)]?.frame = corner
        state.parked[id(3)] = ParkRecord(home: home, parkedFrame: corner, processStart: 1_100)
        let (after, _) = EngineReducer.reduce(state, .command(.resetState, now: 5))
        // A still-parked window keeps its parked record (the journal side), and its workspace is its home display's.
        #expect(after.parked[id(3)] != nil)
        #expect(after.model.workspace(of: id(3)) == after.model.visible[after.displayKey(of: second)])
    }
}
