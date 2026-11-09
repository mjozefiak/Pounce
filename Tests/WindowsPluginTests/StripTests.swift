import AppKit
import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// Step 1.10: the strip on plain values. The status item itself (click positions, accessibility children, room in
/// the menu bar) needs a real menu bar and is a manual item in `docs/qa.md`.
@Suite struct StripTests {
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
}
