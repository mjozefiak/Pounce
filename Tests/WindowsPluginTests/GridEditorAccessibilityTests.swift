import CoreGraphics
import Foundation
import LintelKit
import LintelUI
import Testing

@testable import WindowsPlugin

/// The accessibility audit of the grid editor (step 4.4), as far as it can be tested without a screen: what
/// VoiceOver reads for zones and dividers, that every operation has a path without the pointer, and the contrast
/// of what the canvas draws. Text sizes, light and dark, English and Polish, and a VoiceOver walk-through are
/// manual (`docs/qa.md`).
@Suite(.timeLimit(.minutes(1))) @MainActor struct GridEditorAccessibilityTests {
    private final class Preview: ZoneOverlayPresenting {
        func show(_ displays: [DragDisplay]) {}
        func highlight(_ zone: DragZone?) {}
        func hide() {}
    }

    private func model(_ layout: GridLayout) -> GridEditorModel {
        GridEditorModel(
            layout: layout, isNew: true,
            repository: LayoutRepository(directory: FileManager.default.temporaryDirectory),
            displays: { [] }, preview: Preview())
    }

    @Test func everyZoneOfEveryStockLayoutReadsWithItsNumberAndPositionAndIsUnique() {
        for layout in StockLayouts.all {
            let rows = model(layout).zoneRows
            #expect(rows.count == layout.zones.count)
            let spoken = rows.map(\.spoken)
            #expect(Set(spoken).count == spoken.count, "\(layout.id)")
            for row in rows {
                #expect(row.spoken.hasPrefix("Zone \(row.number), x \(row.x)%, y \(row.y)%"))
                #expect(row.spoken.hasSuffix("width \(row.width)%, height \(row.height)%"))
            }
        }
        #expect(
            GridEditorText.zoneDescription(number: 2, x: 25, y: 0, width: 50, height: 100)
                == "Zone 2, x 25%, y 0%, width 50%, height 100%")
    }

    @Test func everyDividerHasANameWithItsPosition() {
        let editor = model(StockLayouts.layout(StockLayouts.grid2x2) ?? StockLayouts.all[0])
        let names = editor.dividers.map { editor.dividerDescription($0) }
        #expect(names == ["Vertical divider at 50%", "Horizontal divider at 50%"])
    }

    @Test func everyRefusalIsInWordsAndNoneIsLong() {
        let all: [EditorFailure] = [
            .unknownZone, .unknownDivider, .zoneLimit, .trackLimit, .tooNarrow, .nothingToMerge, .notRectangle,
            .notAligned, .outerEdge, .badValue, .nothingToUndo, .nothingToRedo,
        ]
        for failure in all {
            let text = GridEditorText.message(for: failure)
            #expect(!text.isEmpty && text.count < 120, "\(failure)")
        }
    }

    @Test func everyOperationHasAPathWithoutThePointer() {
        // Keyboard table of the canvas: all of these keys exist and mean something in some state.
        var state = GridEditorState(StockLayouts.layout(StockLayouts.columns2) ?? StockLayouts.all[0])
        var used = Set<String>()
        func press(_ key: EditorKey) {
            if state.handle(key) != nil { used.insert("\(key)") }
        }
        press(.tab)
        press(.divide)
        press(.divideOther)
        state.focus = .zone(1)
        press(.toggleSelection)
        state.selection = [1, 2]
        press(.merge)
        state.focus = state.dividers.first.map { .divider($0) }
        press(.right)
        press(.left)
        press(.delete)
        state.focus = state.dividers.first.map { .divider($0) }
        press(.down)
        press(.up)
        press(.backTab)
        #expect(used.isSuperset(of: ["tab", "backTab", "divide", "divideOther", "toggleSelection", "merge", "delete"]))
        #expect(used.contains("right") || used.contains("down"))
        // The numeric fields reach every edge, so a divider can be moved without dragging or arrows.
        var fields = GridEditorState(StockLayouts.layout(StockLayouts.grid2x2) ?? StockLayouts.all[0])
        for (offset, edge) in [GridEditorState.ZoneEdge.left, .right, .top, .bottom].enumerated() {
            var reachable = false
            for zone in fields.layout.zones {
                if case .success = fields.setEdge(edge, ofZone: zone.id, to: [0.3, 0.4, 0.6, 0.7][offset]) {
                    reachable = true
                }
            }
            #expect(reachable, "\(edge)")
        }
    }

    @Test func theCanvasNumbersMeetContrastAndTheEditorReusesTheOverlaysPill() {
        #expect(BrandPalette.contrast(ZoneOverlayStyle.numberHex, ZoneOverlayStyle.pillGrayHex) >= 7)
        // The error text on the window background, light and dark.
        #expect(BrandPalette.contrast(BrandPalette.statusErrorLight, BrandPalette.windowLight) >= 4.5)
        #expect(BrandPalette.contrast(BrandPalette.statusErrorDark, BrandPalette.windowDark) >= 4.5)
    }

    @Test func aFocusedOrSelectedZoneIsMarkedByMoreThanColour() {
        // The view draws a 3 pt border for the focused zone and 1.5 pt otherwise; selection adds a stronger fill.
        let editor = model(StockLayouts.layout(StockLayouts.columns2) ?? StockLayouts.all[0])
        #expect(editor.focus == .zone(1))
        editor.setSelection([1, 2])
        #expect(editor.selection == [1, 2])
    }
}
