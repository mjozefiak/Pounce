import AppKit
import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// Step 1.10: the strip on plain values. The status item itself (click positions, accessibility children, room in
/// the menu bar) needs a real menu bar and is a manual item in `docs/qa.md`.
@Suite(.timeLimit(.minutes(1))) struct StripTests {
    private func summary(
        current: Int, counts: [Int: Int], visible: [String: Int]? = nil
    ) -> WorkspaceSummary {
        WorkspaceSummary(
            current: WorkspaceID(current),
            visible: (visible ?? ["MAIN": current]).compactMapValues { WorkspaceID($0) },
            counts: Dictionary(
                uniqueKeysWithValues: counts.compactMap { key, value in WorkspaceID(key).map { ($0, value) } }))
    }

    // MARK: Which boxes

    @Test func allModeShowsEveryConfiguredWorkspaceSoBoxesNeverMove() {
        let boxes = StripModel.boxes(
            summary: summary(current: 2, counts: [1: 3, 2: 0]), workspaceCount: 4, occupiedOnly: false)
        #expect(boxes.map(\.number) == [1, 2, 3, 4])
        #expect(boxes.map(\.isCurrent) == [false, true, false, false])
        #expect(boxes.map(\.windowCount) == [3, 0, 0, 0])
    }

    @Test func occupiedModeKeepsOccupiedCurrentAndShownWorkspaces() {
        let state = summary(current: 3, counts: [1: 2, 3: 0, 4: 0], visible: ["MAIN": 3, "SECOND": 4])
        let boxes = StripModel.boxes(summary: state, workspaceCount: 6, occupiedOnly: true)
        #expect(boxes.map(\.number) == [1, 3, 4])
        #expect(boxes.first { $0.number == 4 }?.isShownElsewhere == true)
        #expect(boxes.first { $0.number == 3 }?.isShownElsewhere == false)
    }

    @Test func onlyTheCurrentBoxIsActiveAndTheCountIsClamped() {
        let boxes = StripModel.boxes(summary: summary(current: 1, counts: [:]), workspaceCount: 20, occupiedOnly: false)
        #expect(boxes.count == 9)
        #expect(boxes.filter(\.isCurrent).count == 1)
        #expect(
            StripModel.boxes(summary: summary(current: 1, counts: [:]), workspaceCount: 0, occupiedOnly: false).count
                == 1)
    }

    @Test func aBoxIsAnnouncedWithItsNumberItsWindowsAndWhetherItIsCurrent() {
        let current = StripBox(number: 3, windowCount: 4, isCurrent: true, isShownElsewhere: false)
        #expect(StripModel.accessibilityLabel(current).hasPrefix("Workspace 3, "))
        #expect(StripModel.accessibilityLabel(current).hasSuffix(", current"))
        let elsewhere = StripBox(number: 2, windowCount: 0, isCurrent: false, isShownElsewhere: true)
        #expect(StripModel.accessibilityLabel(elsewhere) == "Workspace 2, No windows, shown on another display")
        let other = StripBox(number: 1, windowCount: 0, isCurrent: false, isShownElsewhere: false)
        #expect(StripModel.accessibilityLabel(other) == "Workspace 1, No windows")
    }

    // MARK: Click to index

    @Test func widthGrowsByOneBoxAndAGap() {
        #expect(StripLayout.width(boxCount: 0) == 0)
        #expect(StripLayout.width(boxCount: 1) == 22)
        #expect(StripLayout.width(boxCount: 4) == 82)
        #expect(StripLayout.width(boxCount: 9) == 182)
    }

    @Test func aClickMapsToTheBoxUnderIt() {
        let count = 4
        for index in 0..<count {
            let left = StripLayout.originX(ofBox: index)
            #expect(StripLayout.index(atX: left + 1, boxCount: count) == index)
            #expect(StripLayout.index(atX: left + StripLayout.boxWidth / 2, boxCount: count) == index)
            #expect(StripLayout.index(atX: left + StripLayout.boxWidth - 1, boxCount: count) == index)
        }
    }

    @Test func aClickInAGapGoesToTheNearerBoxAndOutsideIsNothing() {
        // The gap between box 0 and box 1 spans 20...22; its first half belongs to box 0.
        #expect(StripLayout.index(atX: 20.4, boxCount: 4) == 0)
        #expect(StripLayout.index(atX: 21.6, boxCount: 4) == 1)
        // The padding belongs to the end boxes.
        #expect(StripLayout.index(atX: 0.5, boxCount: 4) == 0)
        #expect(StripLayout.index(atX: StripLayout.width(boxCount: 4) - 0.5, boxCount: 4) == 3)
        #expect(StripLayout.index(atX: -1, boxCount: 4) == nil)
        #expect(StripLayout.index(atX: StripLayout.width(boxCount: 4) + 1, boxCount: 4) == nil)
        #expect(StripLayout.index(atX: 5, boxCount: 0) == nil)
    }

    // MARK: Room in the menu bar

    @Test func anItemOutsideEveryScreenOrWithoutSizeHasNoRoom() {
        let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        #expect(StripVisibility.hasRoom(itemFrame: CGRect(x: 1600, y: 1058, width: 80, height: 22), screens: screens))
        #expect(!StripVisibility.hasRoom(itemFrame: CGRect(x: -400, y: 1058, width: 80, height: 22), screens: screens))
        #expect(!StripVisibility.hasRoom(itemFrame: CGRect(x: 1600, y: 1058, width: 0, height: 22), screens: screens))
        #expect(!StripVisibility.hasRoom(itemFrame: nil, screens: screens))
        #expect(!StripVisibility.hasRoom(itemFrame: CGRect(x: 10, y: 10, width: 50, height: 22), screens: []))
    }

    /// QA round 3, B3: with the menu bar set to hide automatically the item's window sits above the screen, and the
    /// pane said there was no room although the strip existed.
    @Test func anItemInTheHiddenMenuBarAboveTheScreenStillHasRoomButOneOffToTheSideDoesNot() {
        let screens = [CGRect(x: 0, y: 0, width: 5120, height: 1440)]
        // Shown in the menu bar, hidden just above the screen, hidden far above.
        #expect(StripVisibility.hasRoom(itemFrame: CGRect(x: 4290, y: 1416, width: 100, height: 24), screens: screens))
        #expect(StripVisibility.hasRoom(itemFrame: CGRect(x: 4290, y: 1440, width: 100, height: 24), screens: screens))
        #expect(StripVisibility.hasRoom(itemFrame: CGRect(x: 4290, y: 1500, width: 100, height: 24), screens: screens))
        // Dropped: beside the screen or without width.
        #expect(!StripVisibility.hasRoom(itemFrame: CGRect(x: 6000, y: 1416, width: 100, height: 24), screens: screens))
        #expect(!StripVisibility.hasRoom(itemFrame: CGRect(x: 4290, y: 1416, width: 0, height: 24), screens: screens))
        // A second display to the right with its own menu bar.
        let two = screens + [CGRect(x: 5120, y: 0, width: 2560, height: 1440)]
        #expect(StripVisibility.hasRoom(itemFrame: CGRect(x: 6000, y: 1416, width: 100, height: 24), screens: two))
        // Low on a screen is not the menu bar.
        #expect(!StripVisibility.hasRoom(itemFrame: CGRect(x: 4290, y: 200, width: 100, height: 24), screens: screens))
    }

    // MARK: The image

    @MainActor
    @Test func theImageIsATemplateAsWideAsItsBoxesAndTheActiveBoxLooksDifferent() throws {
        let boxes = (1...4).map { StripBox(number: $0, windowCount: 0, isCurrent: $0 == 2, isShownElsewhere: false) }
        let image = StripImage.render(boxes)
        #expect(image.isTemplate)
        #expect(image.size.width == StripLayout.width(boxCount: 4))
        let other = StripImage.render(
            boxes.map {
                StripBox(number: $0.number, windowCount: 0, isCurrent: $0.number == 3, isShownElsewhere: false)
            })
        #expect(try #require(image.tiffRepresentation) != (try #require(other.tiffRepresentation)))
        #expect(StripImage.render([]).size.width == 1)
    }

    // MARK: Wiring to the engine

    @MainActor
    @Test func theRuntimeBuildsItsBoxesFromTheEnginesSummary() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1), makeWindow(2)])
        client.setFocused(WindowID(pid: 100, number: 1))
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        try await plugin.activate()
        let runtime = try #require(plugin.runtime)
        #expect(runtime.strip == nil)
        await runtime.engine.send(.moveFocusedWindow(to: WorkspaceID(3)!))
        await runtime.settle()
        #expect(runtime.stripBoxes().first { $0.number == 3 }?.windowCount == 1)
        let boxes = runtime.stripBoxes()
        #expect(boxes.map(\.number) == [1, 2, 3, 4])
        #expect(boxes.first { $0.isCurrent }?.number == 1)
        WindowsSettings(harness.pluginSettings).setStripMode(.occupied)
        #expect(runtime.stripBoxes().map(\.number) == [1, 3])
        await plugin.deactivate()
    }

    // MARK: Click mapping end to end (QA N3)

    /// A click in the button's coordinates: where the image starts, then the box under it.
    private func box(
        clickX: CGFloat, count: Int, buttonWidth: CGFloat, drawnMinX: CGFloat? = nil, drawnWidth: CGFloat? = nil
    ) -> Int? {
        let image = StripLayout.width(boxCount: count)
        let origin = StripLayout.imageOriginX(
            buttonWidth: buttonWidth, imageWidth: image, drawnImageMinX: drawnMinX, drawnImageWidth: drawnWidth)
        return StripLayout.index(atX: clickX - origin, boxCount: count)
    }

    @Test func everyBoxIsHitAtItsCentreForOneToNineBoxesWithTheImageCentredInTheButton() {
        for count in 1...9 {
            let image = StripLayout.width(boxCount: count)
            let buttonWidth = image + 12
            for index in 0..<count {
                let centre = (buttonWidth - image) / 2 + StripLayout.originX(ofBox: index) + StripLayout.boxWidth / 2
                #expect(
                    box(clickX: centre, count: count, buttonWidth: buttonWidth) == index, "\(count) boxes, box \(index)"
                )
            }
        }
    }

    @Test func theCellsDrawnRectWinsOverTheCentringAssumptionWhenItMatchesTheImage() {
        let count = 4
        let image = StripLayout.width(boxCount: count)
        // The image is drawn flush left with 5 points of inset, not centred: the box centres follow the cell.
        for index in 0..<count {
            let centre = 5 + StripLayout.originX(ofBox: index) + StripLayout.boxWidth / 2
            #expect(
                box(clickX: centre, count: count, buttonWidth: image + 40, drawnMinX: 5, drawnWidth: image) == index)
        }
        // A drawn rect of another size is not trusted: the centred origin is used.
        #expect(
            StripLayout.imageOriginX(
                buttonWidth: image + 40, imageWidth: image, drawnImageMinX: 5, drawnImageWidth: image * 2)
                == 20)
    }

    @Test func clicksOutsideTheImageHitNothingAndEdgesBelongToTheEdgeBoxes() {
        let count = 3
        let image = StripLayout.width(boxCount: count)
        let buttonWidth = image + 12
        let origin = (buttonWidth - image) / 2
        #expect(box(clickX: origin - 0.5, count: count, buttonWidth: buttonWidth) == nil)
        #expect(box(clickX: origin + image + 0.5, count: count, buttonWidth: buttonWidth) == nil)
        #expect(box(clickX: origin + 0.1, count: count, buttonWidth: buttonWidth) == 0)
        #expect(box(clickX: origin + image - 0.1, count: count, buttonWidth: buttonWidth) == count - 1)
        // The gap between two boxes goes to the nearer one.
        let gapMiddle = origin + StripLayout.originX(ofBox: 1) - StripLayout.gap / 2
        #expect(box(clickX: gapMiddle - 0.4, count: count, buttonWidth: buttonWidth) == 0)
        #expect(box(clickX: gapMiddle + 0.4, count: count, buttonWidth: buttonWidth) == 1)
    }

    // MARK: The real click path (QA round 3, N3)

    /// What QA observed on macOS 26: the item's window is 100 x 24 at x 4290, the 4-box image (82 pt) is centred in it
    /// (origin 9), and the event reports the click at the item's centre (x 50) whatever was clicked, so the event's x
    /// always chose box 3 of 4 (index 2). The cursor's own screen x is what says where the click was.
    @Test func theCursorPositionNotTheItemCentreChoosesTheBoxWhenTheEventAlwaysReportsTheCentre() {
        let frame = CGRect(x: 4290, y: 3, width: 100, height: 24)
        let origin = StripLayout.imageOriginX(buttonWidth: 100, imageWidth: StripLayout.width(boxCount: 4))
        #expect(origin == 9)
        func box(cursor: CGFloat) -> Int? {
            let x = StripLayout.clickX(eventX: 50, cursorScreenX: cursor, itemFrame: frame) - origin
            return StripLayout.index(atX: x, boxCount: 4)
        }
        // The observed clicks: left of the image, then the four boxes, the right edge and outside.
        #expect(box(cursor: 4296) == nil)
        #expect(box(cursor: 4310) == 0)
        #expect(box(cursor: 4330) == 1)
        #expect(box(cursor: 4350) == 2)
        #expect(box(cursor: 4370) == 3)
        #expect(box(cursor: 4380) == 3)
        #expect(box(cursor: 4388) == nil)
        // The old behaviour, for the record: the event's centre x alone always meant index 2.
        #expect(StripLayout.index(atX: 50 - origin, boxCount: 4) == 2)
    }

    @Test func withoutAUsableCursorTheEventsOwnPositionIsUsed() {
        let frame = CGRect(x: 4290, y: 3, width: 100, height: 24)
        #expect(StripLayout.clickX(eventX: 33, cursorScreenX: nil, itemFrame: frame) == 33)
        #expect(StripLayout.clickX(eventX: 33, cursorScreenX: 4000, itemFrame: frame) == 33)
        #expect(StripLayout.clickX(eventX: 33, cursorScreenX: 4500, itemFrame: frame) == 33)
        #expect(StripLayout.clickX(eventX: 33, cursorScreenX: 4300, itemFrame: nil) == 33)
        #expect(StripLayout.clickX(eventX: 33, cursorScreenX: 4300, itemFrame: frame, buttonMinX: 2) == 8)
    }

    @Test func theBoxScreenRectsAreWhereToClick() {
        let frame = CGRect(x: 4290, y: 3, width: 100, height: 24)
        let rects = StripLayout.boxScreenRects(boxCount: 4, itemFrame: frame, imageOriginX: 9)
        #expect(rects.count == 4)
        // The first box starts after the image's 2 pt padding; neighbours are one box plus a gap apart.
        #expect(rects[0].minX == CGFloat(4290 + 9 + 2))
        #expect(rects[1].minX - rects[0].minX == StripLayout.boxWidth + StripLayout.gap)
        // A click at the middle of each rect maps back to its own box.
        for (index, rect) in rects.enumerated() {
            let x = StripLayout.clickX(eventX: 50, cursorScreenX: rect.midX, itemFrame: frame) - 9
            #expect(StripLayout.index(atX: x, boxCount: 4) == index)
        }
    }
}
