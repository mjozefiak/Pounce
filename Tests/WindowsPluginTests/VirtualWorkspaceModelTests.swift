import LintelKit
import Testing

@testable import WindowsPlugin

@Suite struct VirtualWorkspaceModelTests {
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }
    private func win(_ number: UInt32, pid: Int32 = 100) -> WindowID { WindowID(pid: pid, number: number) }

    @Test func workspaceIDsAreOneThroughNine() {
        #expect(WorkspaceID(0) == nil)
        #expect(WorkspaceID(10) == nil)
        #expect(WorkspaceID(9)?.rawValue == 9)
        #expect(WorkspaceID.all(count: 4).map(\.rawValue) == [1, 2, 3, 4])
        #expect(WorkspaceID.all(count: 40).count == 9)
    }

    @Test func startsWithWorkspaceOneOnTheMainDisplay() {
        let model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["main"])
        #expect(model.current == ws(1))
        #expect(model.visible == ["main": ws(1)])
        #expect(model.focusedDisplay == "main")
        #expect(model.previous == nil)
    }

    @Test func twoDisplaysShowTheFirstTwoWorkspaces() {
        let model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["a", "b"])
        #expect(model.visible == ["a": ws(1), "b": ws(2)])
        #expect(model.displayShowing(ws(2)) == "b")
        #expect(!model.isVisible(ws(3)))
    }

    @Test func moreDisplaysThanWorkspacesLeavesTheLastOnesEmpty() {
        let model = VirtualWorkspaceModel(workspaceCount: 1, displays: ["a", "b"])
        #expect(model.visible == ["a": ws(1)])
    }

    @Test func showingAnotherWorkspaceHidesTheCurrentOne() {
        var model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["main"])
        let change = model.show(ws(3))
        #expect(change.hidden == [ws(1)])
        #expect(change.shown == [ws(3)])
        #expect(model.current == ws(3))
        #expect(model.previous == ws(1))
    }

    @Test func showingTheCurrentWorkspaceChangesNothing() {
        var model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["main"])
        let change = model.show(ws(1))
        #expect(change.isEmpty)
        #expect(model.previous == nil)
    }

    @Test func showingAnUnknownWorkspaceChangesNothing() {
        var model = VirtualWorkspaceModel(workspaceCount: 3, displays: ["main"])
        let r1 = model.show(ws(7))
        #expect(r1.isEmpty)
        #expect(model.current == ws(1))
    }

    @Test func showingAWorkspaceOfAnotherDisplayMovesTheFocusThere() {
        var model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["a", "b"])
        let change = model.show(ws(2))
        #expect(change.isEmpty)
        #expect(change.focusedDisplay == "b")
        #expect(model.focusedDisplay == "b")
        #expect(model.visible == ["a": ws(1), "b": ws(2)])
        #expect(model.previous == ws(1))
    }

    @Test func backAndForthTogglesBetweenTheTwoLastWorkspaces() {
        var model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["main"])
        let r2 = model.back()
        #expect(r2.isEmpty)
        model.show(ws(2))
        let r3 = model.back()
        #expect(r3.shown == [ws(1)])
        #expect(model.current == ws(1))
        let r4 = model.back()
        #expect(r4.shown == [ws(2)])
        #expect(model.current == ws(2))
    }

    @Test func nextAndPreviousWrapAround() {
        var model = VirtualWorkspaceModel(workspaceCount: 3, displays: ["main"])
        model.next()
        model.next()
        #expect(model.current == ws(3))
        model.next()
        #expect(model.current == ws(1))
        model.previousByNumber()
        #expect(model.current == ws(3))
    }

    @Test func newWindowsJoinTheWorkspaceShownOnTheirDisplay() {
        var model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["a", "b"])
        let r5 = model.add(win(1), onDisplay: "b") == ws(2)
        #expect(r5)
        let r6 = model.add(win(2)) == ws(1)
        #expect(r6)
        let r7 = model.add(win(3), to: ws(4)) == ws(4)
        #expect(r7)
        #expect(model.workspace(of: win(1)) == ws(2))
        #expect(model.windows(in: ws(4)) == [win(3)])
        #expect(model.hiddenWindows == [win(3)])
    }

    @Test func aKnownWindowIsNotAddedTwice() {
        var model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["main"])
        model.add(win(1), to: ws(3))
        let r8 = model.add(win(1), to: ws(1)) == ws(3)
        #expect(r8)
        #expect(model.windowCount(in: ws(3)) == 1)
        #expect(model.windowCount(in: ws(1)) == 0)
    }

    @Test func movingAWindowChangesExactlyOneMembership() {
        var model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["main"])
        model.add(win(1))
        model.add(win(2))
        let r9 = model.move(win(1), to: ws(3))
        #expect(r9)
        #expect(model.windows(in: ws(1)) == [win(2)])
        #expect(model.windows(in: ws(3)) == [win(1)])
        let r10 = model.move(win(1), to: ws(3))
        #expect(!r10)
        let r11 = model.move(win(9), to: ws(2))
        #expect(!r11)
        let r12 = model.move(win(1), to: ws(8))
        #expect(!r12)
    }

    @Test func removingTheLastWindowDropsTheWorkspaceEntry() {
        var model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["main"])
        model.add(win(1))
        model.remove(win(1))
        model.remove(win(1))
        #expect(model.order.isEmpty)
        #expect(model.workspace(of: win(1)) == nil)
    }

    @Test func reconcileDropsGoneWindowsAndAddsNewOnes() {
        var model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["a", "b"])
        model.add(win(1), to: ws(3))
        model.add(win(2), to: ws(1))
        model.reconcile(live: [(win(1), "a"), (win(5), "b")])
        #expect(model.workspace(of: win(2)) == nil)
        #expect(model.workspace(of: win(1)) == ws(3))
        #expect(model.workspace(of: win(5)) == ws(2))
    }

    @Test func shrinkingTheCountMovesWindowsToTheLastWorkspace() {
        var model = VirtualWorkspaceModel(workspaceCount: 5, displays: ["main"])
        model.add(win(1), to: ws(4))
        model.add(win(2), to: ws(5))
        model.add(win(3), to: ws(2))
        model.show(ws(5))
        model.setWorkspaceCount(3)
        #expect(model.workspaces == [ws(1), ws(2), ws(3)])
        #expect(model.windows(in: ws(3)) == [win(1), win(2)])
        #expect(model.windows(in: ws(2)) == [win(3)])
        // The display that showed workspace 5 shows the lowest workspace nobody shows.
        #expect(model.current == ws(1))
        #expect(model.previous == ws(1))
    }

    @Test func growingTheCountKeepsEverything() {
        var model = VirtualWorkspaceModel(workspaceCount: 2, displays: ["main"])
        model.add(win(1), to: ws(2))
        model.setWorkspaceCount(6)
        #expect(model.workspaces.count == 6)
        #expect(model.workspace(of: win(1)) == ws(2))
    }

    @Test func aRemovedDisplayHidesItsWorkspaceAndTheFocusMovesToTheMainDisplay() {
        var model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["a", "b"])
        model.add(win(1), to: ws(2))
        model.show(ws(2))
        #expect(model.focusedDisplay == "b")
        model.setDisplays(["a"])
        #expect(model.focusedDisplay == "a")
        #expect(!model.isVisible(ws(2)))
        #expect(model.hiddenWindows == [win(1)])
        #expect(model.previous == nil)
    }

    @Test func aNewDisplayShowsTheLowestWorkspaceNobodyShows() {
        var model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["a"])
        model.show(ws(2))
        model.setDisplays(["a", "b"])
        #expect(model.visible == ["a": ws(2), "b": ws(1)])
    }

    @Test func displayOrderIsStableAndDuplicatesAreIgnored() {
        let model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["a", "b", "a"])
        #expect(model.displays == ["a", "b"])
    }

    @Test func restoringTheStoredOrderDropsWhatDoesNotFit() {
        var model = VirtualWorkspaceModel(workspaceCount: 3, displays: ["main"])
        model.restore(order: [ws(1): [win(1), win(2)], ws(2): [win(2), win(3)], ws(6): [win(4)]])
        #expect(model.windows(in: ws(1)) == [win(1), win(2)])
        #expect(model.windows(in: ws(2)) == [win(3)])
        #expect(model.workspace(of: win(4)) == nil)
    }

    @Test func focusingAnotherDisplayRemembersTheWorkspaceForBack() {
        var model = VirtualWorkspaceModel(workspaceCount: 4, displays: ["a", "b"])
        model.focusDisplay("b")
        #expect(model.current == ws(2))
        #expect(model.previous == ws(1))
        model.focusDisplay("nope")
        #expect(model.focusedDisplay == "b")
    }
}
