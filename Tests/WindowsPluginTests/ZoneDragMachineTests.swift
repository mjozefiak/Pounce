import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// The drag state machine (step 3.5a) on scripted events: when the overlay is wanted, highlight, snap, cancel.
@Suite struct ZoneDragMachineTests {
    private let window = WindowID(pid: 1, number: 1)
    private let other = WindowID(pid: 1, number: 2)

    private let leftZone = DragZone(
        displayKey: "A", zoneID: 1, number: 1, frame: CGRect(x: 0, y: 0, width: 500, height: 600))
    private let rightZone = DragZone(
        displayKey: "A", zoneID: 2, number: 2, frame: CGRect(x: 510, y: 0, width: 490, height: 600))
    private var displays: [DragDisplay] {
        [DragDisplay(key: "A", area: CGRect(x: 0, y: 0, width: 1000, height: 600), zones: [leftZone, rightZone])]
    }

    private func sample(down: Bool = true, shift: Bool = true, x: CGFloat = 100, y: CGFloat = 100) -> PointerSample {
        PointerSample(leftButtonDown: down, shiftDown: shift, cursor: CGPoint(x: x, y: y))
    }

    /// A machine in the overlay phase with the two zones known.
    private func overlayMachine() -> ZoneDragMachine {
        var machine = ZoneDragMachine()
        _ = machine.handle(.windowMoved(window, sample()))
        _ = machine.handle(.displays(displays))
        return machine
    }

    // MARK: When the overlay is wanted

    @Test func aMovedWindowWithTheButtonDownAndShiftShowsTheOverlay() {
        var machine = ZoneDragMachine()
        let effects = machine.handle(.windowMoved(window, sample()))
        #expect(effects == [.showOverlay(window)])
        #expect(machine.phase == .overlay(window))
        #expect(machine.isOverlayVisible)
    }

    @Test func aMovedWindowWithoutShiftOnlyStartsADrag() {
        var machine = ZoneDragMachine()
        #expect(machine.handle(.windowMoved(window, sample(shift: false))).isEmpty)
        #expect(machine.phase == .dragging(window))
        #expect(!machine.isOverlayVisible)
    }

    @Test func aMovedWindowWithTheButtonUpIsIgnored() {
        // A window that moved on its own (an app restoring its position, our own layout) never shows the overlay.
        var machine = ZoneDragMachine()
        #expect(machine.handle(.windowMoved(window, sample(down: false))).isEmpty)
        #expect(machine.phase == .idle)
    }

    @Test func pointerSamplesAloneNeverStartADrag() {
        // Shift held with the button down and the mouse moving, but no managed window moved: a text selection or a
        // Finder drag.
        var machine = ZoneDragMachine()
        for x in stride(from: 0, to: 500, by: 50) { #expect(machine.handle(.pointer(sample(x: CGFloat(x)))).isEmpty) }
        #expect(machine.phase == .idle)
    }

    @Test func shiftPressedMidDragShowsTheOverlayAndReleasedHidesIt() {
        var machine = ZoneDragMachine()
        _ = machine.handle(.windowMoved(window, sample(shift: false)))
        #expect(machine.handle(.pointer(sample(shift: false))).isEmpty)
        #expect(machine.handle(.pointer(sample(shift: true))) == [.showOverlay(window)])
        #expect(machine.handle(.pointer(sample(shift: false))) == [.hideOverlay])
        #expect(machine.phase == .dragging(window))
        #expect(machine.highlighted == nil)
        // And again: the drag is still alive.
        #expect(machine.handle(.pointer(sample(shift: true))) == [.showOverlay(window)])
    }

    @Test func eventsOfAnotherWindowDoNotDisturbTheDrag() {
        var machine = overlayMachine()
        #expect(machine.handle(.windowMoved(other, sample(down: false, shift: false))).isEmpty)
        #expect(machine.handle(.windowMoved(other, sample())).isEmpty)
        #expect(machine.phase == .overlay(window))
    }

    // MARK: Highlight

    @Test func theZoneUnderTheCursorIsHighlighted() {
        var machine = ZoneDragMachine()
        _ = machine.handle(.windowMoved(window, sample(x: 100)))
        // The controller answers the show request with the zones; the cursor is over the left one.
        #expect(machine.handle(.displays(displays)) == [.highlight(leftZone)])
        #expect(machine.handle(.pointer(sample(x: 120))).isEmpty)
        #expect(machine.handle(.pointer(sample(x: 800))) == [.highlight(rightZone)])
        #expect(machine.highlighted == rightZone)
    }

    @Test func aCursorInTheGapPicksTheNearestZoneAndOutsideEveryDisplayPicksNone() {
        var machine = overlayMachine()
        #expect(machine.zone(at: CGPoint(x: 504, y: 100)) == leftZone)
        #expect(machine.zone(at: CGPoint(x: 508, y: 100)) == rightZone)
        #expect(machine.zone(at: CGPoint(x: 2000, y: 100)) == nil)
        #expect(machine.handle(.pointer(sample(x: 2000))) == [.highlight(nil)])
    }

    // MARK: Release

    @Test func releasingOverAZoneWithShiftHeldSnapsAndHidesTheOverlay() {
        var machine = overlayMachine()
        _ = machine.handle(.pointer(sample(x: 800)))
        let effects = machine.handle(.pointer(sample(down: false, shift: true, x: 800)))
        #expect(effects == [.hideOverlay, .snap(window, rightZone)])
        #expect(machine.phase == .idle)
        #expect(machine.highlighted == nil)
        // Done: later samples do nothing.
        #expect(machine.handle(.pointer(sample(x: 100))).isEmpty)
    }

    @Test func aReleaseThroughAMovedEventSnapsToo() {
        var machine = overlayMachine()
        let effects = machine.handle(.windowMoved(window, sample(down: false, shift: true, x: 100)))
        #expect(effects == [.hideOverlay, .snap(window, leftZone)])
    }

    @Test func releasingShiftBeforeTheButtonDoesNotSnap() {
        var machine = overlayMachine()
        _ = machine.handle(.pointer(sample(shift: false)))
        #expect(machine.handle(.pointer(sample(down: false, shift: false))).isEmpty)
        #expect(machine.phase == .idle)
    }

    @Test func releasingAwayFromEveryZoneHidesTheOverlayWithoutSnapping() {
        var machine = overlayMachine()
        let effects = machine.handle(.pointer(sample(down: false, shift: true, x: 5000)))
        #expect(effects == [.hideOverlay])
        #expect(machine.phase == .idle)
    }

    @Test func releasingAPlainDragDoesNothing() {
        var machine = ZoneDragMachine()
        _ = machine.handle(.windowMoved(window, sample(shift: false)))
        #expect(machine.handle(.pointer(sample(down: false, shift: false))).isEmpty)
        #expect(machine.phase == .idle)
    }

    // MARK: Cancel

    @Test func theWindowClosingOrACancelEndsTheDragAndHidesTheOverlay() {
        var machine = overlayMachine()
        #expect(machine.handle(.windowGone(other)).isEmpty)
        #expect(machine.handle(.windowGone(window)) == [.hideOverlay])
        #expect(machine.phase == .idle)
        machine = overlayMachine()
        #expect(machine.handle(.cancel) == [.hideOverlay])
        #expect(machine.handle(.cancel).isEmpty)
        var plain = ZoneDragMachine()
        _ = plain.handle(.windowMoved(window, sample(shift: false)))
        #expect(plain.handle(.cancel).isEmpty)
        #expect(plain.phase == .idle)
    }

    @Test func zonesSentWhenNoOverlayIsUpAreRememberedButHighlightNothing() {
        var machine = ZoneDragMachine()
        #expect(machine.handle(.displays(displays)).isEmpty)
        // The overlay later appears over remembered zones, and a fresh drag forgets them on finish.
        _ = machine.handle(.windowMoved(window, sample()))
        #expect(machine.highlighted == leftZone)
        _ = machine.handle(.pointer(sample(down: false)))
        #expect(machine.displays.isEmpty)
    }
}
