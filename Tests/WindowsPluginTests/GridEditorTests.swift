import Foundation
import Testing

@testable import WindowsPlugin

/// The pure grid editor (step 4.2): divide, merge, move a divider, delete a divider, spacing, undo and redo, Tab
/// navigation and the keyboard table.
@Suite(.timeLimit(.minutes(1))) struct GridEditorTests {
    private func stock(_ id: String) -> GridLayout { StockLayouts.layout(id) ?? StockLayouts.all[0] }

    private func state(_ id: String = StockLayouts.focus) -> GridEditorState { GridEditorState(stock(id)) }

    private func succeeded(_ result: Result<Void, EditorFailure>?) -> Bool {
        if case .success? = result { return true }
        return false
    }

    private func failure(_ result: Result<Void, EditorFailure>?) -> EditorFailure? {
        if case .failure(let reason)? = result { return reason }
        return nil
    }

    /// The layout of mockup 03: a tall left zone, a wide top right zone and two zones under it.
    private func mockup() -> GridEditorState {
        var editor = state()
        #expect(succeeded(editor.divide(zone: 1, axis: .vertical)))
        #expect(succeeded(editor.divide(zone: 2, axis: .horizontal)))
        #expect(succeeded(editor.divide(zone: 3, axis: .vertical)))
        return editor
    }

    // MARK: Divide

    @Test func dividingAOneTrackZoneSplitsTheTrackAndKeepsTheLayoutValid() {
        var editor = state()
        #expect(succeeded(editor.divide(zone: 1, axis: .vertical)))
        #expect(editor.layout.columns == [0.5, 0.5])
        #expect(editor.layout.zones.map(\.id) == [1, 2])
        #expect(editor.layout.isValid)
        #expect(succeeded(editor.divide(zone: 2, axis: .horizontal, share: 0.25)))
        #expect(editor.layout.rows == [0.25, 0.75])
        // The new zone sits right after the one it came from, so the numbers read left to right.
        #expect(editor.layout.zones.map(\.id) == [1, 2, 3])
        #expect(editor.layout.isValid)
        #expect(editor.isDirty)
    }

    @Test func dividingNextToAZoneThatSpansTheSplitTrackExtendsThatZone() throws {
        var editor = mockup()
        let layout = editor.layout
        #expect(layout.isValid)
        #expect(layout.zones.count == 4)
        // Zone 1 is still the full-height left half; zone 2 the top right; 3 and 4 below.
        #expect(editor.percentages(ofZone: 1)! == (0, 0, 50, 100))
        #expect(editor.percentages(ofZone: 2)! == (50, 0, 50, 50))
        #expect(editor.percentages(ofZone: 3)! == (50, 50, 25, 50))
        #expect(editor.percentages(ofZone: 4)! == (75, 50, 25, 50))
        _ = editor.undo()
    }

    @Test func aZoneThatCoversSeveralTracksIsDividedAtTheNearestBoundary() {
        var editor = state(StockLayouts.columns3)
        // Merge 1 and 2 first so zone 1 spans two tracks, then divide it: it splits at their shared boundary.
        editor.selection = [1, 2]
        #expect(succeeded(editor.mergeSelection()))
        #expect(editor.layout.columns.count == 2)
        #expect(succeeded(editor.divide(zone: 1, axis: .vertical)))
        #expect(editor.layout.zones.count == 3)
        #expect(editor.layout.columns.count == 3)
    }

    @Test func limitsOnZonesAndTracksAreEnforced() {
        var editor = state()
        for _ in 0..<31 { #expect(succeeded(editor.divide(zone: editor.layout.zones.last?.id ?? 1, axis: .vertical))) }
        #expect(editor.layout.columns.count == 32)
        let before = editor.layout
        #expect(failure(editor.divide(zone: 1, axis: .vertical)) == .trackLimit)
        #expect(editor.layout == before)
        // Rows: 32 more zones keep going until 64 zones.
        for _ in 0..<31 { #expect(succeeded(editor.divide(zone: 1, axis: .horizontal))) }
        #expect(editor.layout.zones.count == 63)
        #expect(succeeded(editor.divide(zone: 2, axis: .horizontal)))
        #expect(editor.layout.zones.count == 64)
        #expect(failure(editor.divide(zone: 2, axis: .horizontal)) == .zoneLimit)
        #expect(editor.layout.isValid)
        #expect(failure(editor.divide(zone: 99, axis: .vertical)) == .unknownZone)
    }

    // MARK: Merge

    @Test func selectedZonesThatMakeARectangleMerge() {
        var editor = mockup()
        editor.selection = [3, 4]
        #expect(succeeded(editor.mergeSelection()))
        #expect(editor.layout.zones.count == 3)
        #expect(editor.layout.isValid)
        // The now unused boundary is gone: the columns are 50/50 again.
        #expect(editor.layout.columns.count == 2)
        #expect(editor.percentages(ofZone: 3)! == (50, 50, 50, 50))
        #expect(editor.selection == [3])
    }

    @Test func zonesThatDoNotMakeARectangleDoNotMerge() {
        var editor = mockup()
        let before = editor.layout
        editor.selection = [1, 4]
        #expect(failure(editor.mergeSelection()) == .notRectangle)
        editor.selection = [3]
        #expect(failure(editor.mergeSelection()) == .nothingToMerge)
        editor.selection = [2, 3, 4]
        #expect(succeeded(editor.mergeSelection()))
        #expect(editor.layout.zones.count == 2)
        #expect(editor.layout != before)
        #expect(editor.layout.isValid)
    }

    // MARK: Dividers

    @Test func aDividerMovesAndStopsOnePercentFromItsNeighbour() {
        var editor = state(StockLayouts.columns2)
        let divider = DividerRef(axis: .vertical, index: 1)
        #expect(succeeded(editor.moveDivider(divider, by: 0.01)))
        #expect(abs(editor.position(of: divider)! - 0.51) < 1e-9)
        #expect(succeeded(editor.moveDivider(divider, to: 0.9)))
        #expect(abs(editor.position(of: divider)! - 0.9) < 1e-9)
        #expect(succeeded(editor.moveDivider(divider, to: 1)))
        #expect(abs(editor.position(of: divider)! - 0.99) < 1e-9)
        #expect(failure(editor.moveDivider(divider, by: 0.01)) == .tooNarrow)
        #expect(succeeded(editor.moveDivider(divider, to: 0)))
        #expect(abs(editor.position(of: divider)! - 0.01) < 1e-9)
        #expect(editor.layout.isValid)
        #expect(failure(editor.moveDivider(DividerRef(axis: .vertical, index: 5), by: 0.01)) == .unknownDivider)
        #expect(failure(editor.moveDivider(divider, by: .nan)) == .badValue)
    }

    @Test func deletingADividerMergesTheZonesOnBothSidesWhenTheyLineUp() {
        var editor = state(StockLayouts.grid2x2)
        #expect(succeeded(editor.removeDivider(DividerRef(axis: .vertical, index: 1))))
        #expect(editor.layout.zones.count == 2)
        #expect(editor.layout.columns.count == 1)
        #expect(editor.layout.isValid)
        #expect(editor.percentages(ofZone: 1)! == (0, 0, 100, 50))
    }

    @Test func deletingADividerWhoseZonesDoNotLineUpChangesNothing() {
        var editor = mockup()
        let before = editor.layout
        #expect(failure(editor.removeDivider(DividerRef(axis: .vertical, index: 1))) == .notAligned)
        #expect(editor.layout == before)
    }

    // MARK: Numeric fields

    @Test func anEdgeFieldMovesTheDividerAndTheBorderOfTheDisplayStaysPut() {
        var editor = state(StockLayouts.columns2)
        #expect(succeeded(editor.setEdge(.left, ofZone: 2, to: 0.25)))
        #expect(editor.percentages(ofZone: 1)! == (0, 0, 25, 100))
        #expect(editor.percentages(ofZone: 2)! == (25, 0, 75, 100))
        #expect(succeeded(editor.setEdge(.right, ofZone: 1, to: 0.4)))
        #expect(editor.percentages(ofZone: 2)! == (40, 0, 60, 100))
        #expect(failure(editor.setEdge(.left, ofZone: 1, to: 0.1)) == .outerEdge)
        #expect(failure(editor.setEdge(.top, ofZone: 1, to: 0.1)) == .outerEdge)
        #expect(failure(editor.setEdge(.left, ofZone: 2, to: 1.5)) == .badValue)
        #expect(failure(editor.setEdge(.left, ofZone: 2, to: .infinity)) == .badValue)
        #expect(failure(editor.setEdge(.left, ofZone: 9, to: 0.5)) == .unknownZone)
    }

    // MARK: Spacing and name

    @Test func spacingStaysBetweenZeroAndSixtyFour() {
        var editor = state()
        #expect(succeeded(editor.setSpacing(0)))
        #expect(succeeded(editor.setSpacing(64)))
        #expect(failure(editor.setSpacing(65)) == .badValue)
        #expect(failure(editor.setSpacing(-1)) == .badValue)
        #expect(editor.layout.spacing == 64)
    }

    @Test func theNameIsPartOfSavingRules() {
        var editor = state()
        #expect(editor.canSave)
        editor.setName("   ")
        #expect(!editor.canSave)
        editor.setName("Coding")
        #expect(editor.canSave)
        editor.setName(String(repeating: "x", count: 65))
        #expect(!editor.canSave)
    }

    // MARK: Undo and redo

    @Test func undoAndRedoWalkTheHistoryAndANewEditClearsRedo() {
        var editor = state()
        #expect(!editor.canUndo && !editor.canRedo && !editor.isDirty)
        _ = editor.divide(zone: 1, axis: .vertical)
        _ = editor.divide(zone: 2, axis: .horizontal)
        #expect(editor.layout.zones.count == 3)
        #expect(succeeded(editor.undo()))
        #expect(editor.layout.zones.count == 2)
        #expect(editor.canRedo)
        #expect(succeeded(editor.redo()))
        #expect(editor.layout.zones.count == 3)
        _ = editor.undo()
        _ = editor.undo()
        #expect(editor.layout == editor.original)
        #expect(!editor.isDirty)
        #expect(failure(editor.undo()) == .nothingToUndo)
        _ = editor.divide(zone: 1, axis: .horizontal)
        #expect(!editor.canRedo)
        #expect(failure(editor.redo()) == .nothingToRedo)
    }

    @Test func undoDropsASelectionAndFocusThatNoLongerExist() {
        var editor = state()
        _ = editor.divide(zone: 1, axis: .vertical)
        editor.focus = .zone(2)
        editor.selection = []
        editor.selection = [1, 2]
        _ = editor.undo()
        #expect(editor.selection == [1])
        #expect(editor.focus == .zone(1))
    }

    @Test func theHistoryIsBounded() {
        var editor = state(StockLayouts.columns2)
        let divider = DividerRef(axis: .vertical, index: 1)
        for index in 0..<(GridEditorState.historyLimit + 20) {
            _ = editor.moveDivider(divider, to: index % 2 == 0 ? 0.3 : 0.7)
        }
        #expect(editor.undoStack.count <= GridEditorState.historyLimit)
    }

    // MARK: Keyboard

    @Test func tabWalksZonesThenDividersAndWraps() {
        var editor = state(StockLayouts.grid2x2)
        #expect(editor.focus == .zone(1))
        let order = editor.focusOrder
        #expect(order.count == 6)
        for expected in order.dropFirst() {
            editor.handle(.tab)
            #expect(editor.focus == expected)
        }
        editor.handle(.tab)
        #expect(editor.focus == .zone(1))
        editor.handle(.backTab)
        #expect(editor.focus == order.last)
        #expect(
            order.suffix(2) == [
                .divider(DividerRef(axis: .vertical, index: 1)), .divider(DividerRef(axis: .horizontal, index: 1)),
            ])
    }

    @Test func theKeyboardTable() {
        var editor = state(StockLayouts.columns2)
        // On a zone: S and ⇧S divide, arrows and Delete mean nothing.
        #expect(editor.handle(.left) == nil)
        #expect(editor.handle(.delete) == nil)
        #expect(succeeded(editor.handle(.divide)))
        #expect(editor.layout.zones.count == 3)
        #expect(succeeded(editor.handle(.divideOther)))
        #expect(editor.layout.zones.count == 4)
        // Space selects the focused zone, M merges the selection.
        editor.focus = .zone(2)
        editor.selection = []
        editor.handle(.toggleSelection)
        #expect(editor.selection == [2])
        editor.handle(.toggleSelection)
        #expect(editor.selection.isEmpty)
        #expect(failure(editor.handle(.merge)) == .nothingToMerge)
        // On a divider: arrows along its axis move it by 1%, the others mean nothing, Delete removes it.
        let divider = DividerRef(axis: .vertical, index: 1)
        editor.focus = .divider(divider)
        let start = editor.position(of: divider)!
        #expect(succeeded(editor.handle(.right)))
        #expect(abs(editor.position(of: divider)! - (start + 0.01)) < 1e-9)
        #expect(succeeded(editor.handle(.left)))
        #expect(abs(editor.position(of: divider)! - start) < 1e-9)
        #expect(editor.handle(.up) == nil)
        #expect(editor.handle(.down) == nil)
        #expect(editor.handle(.divide) == nil)
        let horizontal = DividerRef(axis: .horizontal, index: 1)
        editor.focus = .divider(horizontal)
        #expect(succeeded(editor.handle(.down)))
        #expect(editor.handle(.left) == nil)
    }

    // MARK: Invariant

    @Test func anySequenceOfEditsKeepsTheLayoutValid() {
        var editor = state()
        var seed: UInt64 = 42
        func next(_ limit: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(limit))
        }
        for _ in 0..<400 {
            let zones = editor.layout.zones
            switch next(6) {
            case 0:
                _ = editor.divide(zone: zones[next(zones.count)].id, axis: .vertical, share: Double(next(100)) / 100)
            case 1: _ = editor.divide(zone: zones[next(zones.count)].id, axis: .horizontal)
            case 2:
                editor.selection = Set((0..<3).map { _ in zones[next(zones.count)].id })
                _ = editor.mergeSelection()
            case 3:
                let all = editor.dividers
                if !all.isEmpty { _ = editor.removeDivider(all[next(all.count)]) }
            case 4:
                let all = editor.dividers
                if !all.isEmpty { _ = editor.moveDivider(all[next(all.count)], to: Double(next(101)) / 100) }
            default: _ = editor.undo()
            }
            #expect(editor.layout.isValid)
            #expect(editor.layout.zones.count <= GridLayout.maximumZones)
        }
    }
}
