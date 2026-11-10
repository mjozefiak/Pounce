import CoreGraphics
import Foundation
import LintelKit
import Testing

import struct SwiftUI.Binding

@testable import LintelUI
@testable import WindowsPlugin

@MainActor
private final class RecordingPreview: ZoneOverlayPresenting {
    var shown: [[DragDisplay]] = []
    var highlighted: DragZone?
    var hidden = 0
    func show(_ displays: [DragDisplay]) { shown.append(displays) }
    func highlight(_ zone: DragZone?) { highlighted = zone }
    func hide() { hidden += 1 }
}

/// The editor model (step 4.2): saving, the question on the way out, the live preview, drag grouping, the zone
/// list's words and the Tab rule.
@MainActor @Suite struct GridEditorModelTests {
    private struct Rig {
        var model: GridEditorModel
        var preview: RecordingPreview
        var repository: LayoutRepository
        var directory: URL
        var closed: Closed
        var saved: Saved
    }

    @MainActor final class Closed { var count = 0 }
    @MainActor final class Saved { var layouts: [GridLayout] = [] }

    private func rig(
        _ layout: GridLayout = StockLayouts.layout(StockLayouts.columns2)!, isNew: Bool = true,
        displays: [DisplayInfo] = [
            DisplayInfo(id: 1, uuid: "A", frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), isMain: true)
        ]
    ) async throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appending(path: "lintel-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = LayoutRepository(directory: directory)
        var draft = layout
        if !isNew { draft = try await repository.create(layout) }
        let preview = RecordingPreview()
        let closed = Closed()
        let saved = Saved()
        let model = GridEditorModel(
            layout: draft, isNew: isNew, repository: repository, displays: { displays }, preview: preview,
            onSaved: { saved.layouts.append($0) }, onClose: { closed.count += 1 })
        await model.open()
        return Rig(
            model: model, preview: preview, repository: repository, directory: directory, closed: closed, saved: saved)
    }

    /// Round-13 audit M1: S (divide the focused zone) used to halve a track down to the 32-track limit, a sliver of
    /// about 2^-31. A keyed divide stops at the 1 % floor, says so, and a refused divide changes nothing.
    @Test func repeatedKeyDividesStopAtTheOnePercentFloorAndARefusalChangesNothing() async throws {
        let rig = try await rig(StockLayouts.layout(StockLayouts.columns2)!)
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let model = rig.model
        // Focus the right zone and divide it again and again by key.
        model.setSelection([2])
        var refusedAt: Int?
        for round in 1...40 {
            let before = model.layout
            let canUndoBefore = model.canUndo
            model.setSelection([model.layout.zones.last!.id])
            model.divideFocused(axis: .vertical)
            if model.layout == before {
                refusedAt = round
                #expect(model.canUndo == canUndoBefore)
                break
            }
        }
        let round = try #require(refusedAt, "the divide was never refused")
        #expect(round < 40)
        let total = model.layout.columns.reduce(0, +)
        #expect(model.layout.columns.allSatisfy { $0 / total >= GridEditorState.minimumShare - 1e-9 })
        #expect(model.message == GridEditorText.message(for: .tooNarrow))
        // The refusal is not an undo step: one undo removes only the last successful divide.
        let columns = model.layout.columns.count
        model.undo()
        #expect(model.layout.columns.count == columns - 1)
    }

    /// QA D7: the list highlighted Zone 2 while the detail line showed Zone 1. The detail shows the focused zone and
    /// the list marks the selection, so whenever the focus is a zone and something is selected, the focused zone is
    /// selected.
    @Test func theListMarksTheZoneTheDetailShowsAfterEveryKindOfMove() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let model = rig.model
        func check(_ step: String) {
            guard case .zone(let id)? = model.focus, !model.selection.isEmpty else { return }
            #expect(model.selection.contains(id), "after \(step): focus \(id), selection \(model.selection)")
        }
        model.divide(zone: 2, axis: .horizontal)
        check("divide by zone")
        _ = model.handle(.tab)
        check("tab")
        _ = model.handle(.tab)
        check("tab again")
        _ = model.handle(.backTab)
        check("back tab")
        model.toggleSelection(zone: 1)
        check("toggle on")
        model.toggleSelection(zone: 1)
        check("toggle off")
        model.setSelection([2, 3])
        check("select two")
        _ = model.handle(.divide)
        check("divide by key")
        _ = model.handle(.tab)
        _ = model.handle(.tab)
        _ = model.handle(.tab)
        check("tab through")
        model.setSelection([1])
        check("select one")
    }

    /// QA: Shift+Tab from a divider once landed on the zone list. The canvas keeps the key until the first element of
    /// its own loop: from the first divider it goes back to the last zone; only Shift+Tab on the first zone leaves.
    @Test func shiftTabFromADividerWalksBackThroughTheCanvasAndOnlyTheFirstZoneLeavesIt() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let model = rig.model
        let order = model.state.focusOrder
        let firstDivider = try #require(order.first { if case .divider = $0 { true } else { false } })
        let lastZone = try #require(order.last { if case .zone = $0 { true } else { false } })
        // Walk forward with Tab from the first zone until the first divider has the focus.
        for _ in 0..<order.count where model.focus != firstDivider { #expect(model.handle(.tab)) }
        #expect(model.focus == firstDivider)
        #expect(model.handle(.backTab))
        #expect(model.focus == lastZone)
        // Back to the start of the loop: Shift+Tab on the first element passes on.
        for _ in 0..<order.count where model.focus != order.first { #expect(model.handle(.backTab)) }
        #expect(model.focus == order.first)
        #expect(!model.handle(.backTab))
        // Tab on the last element passes on the same way.
        for _ in 0..<order.count where model.focus != order.last { #expect(model.handle(.tab)) }
        #expect(!model.handle(.tab))
    }

    @Test func theZoneListReadsLikeTheSpec() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        rig.model.divide(zone: 2, axis: .horizontal)
        rig.model.divide(zone: 1, axis: .vertical, share: 0.5)
        let rows = rig.model.zoneRows
        #expect(rows.map(\.number) == [1, 2, 3, 4])
        #expect(rows[0].spoken == "Zone 1, x 0%, y 0%, width 25%, height 100%")
        #expect(rows[0].summary == "0 / 0 / 25 / 100")
        #expect(rows[3].spoken == "Zone 4, x 50%, y 50%, width 50%, height 50%")
    }

    @Test func aNewLayoutIsAddedToTheLibraryOnSave() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        rig.model.setName("Coding")
        rig.model.divide(zone: 1, axis: .horizontal)
        await rig.model.save()
        let stored = await rig.repository.userLayouts
        #expect(stored.count == 1)
        #expect(stored[0].name == "Coding")
        #expect(stored[0].zones.count == 3)
        #expect(rig.saved.layouts == stored)
        #expect(rig.closed.count == 1)
    }

    /// The editor's discard sheet runs through the same `confirmThenClose`: the confirm is synchronous, so closing the
    /// sheet afterwards (which clears `confirmingDiscard`) cannot undo it.
    @Test func confirmingTheDiscardSheetClosesTheEditorAndCancelKeepsItOpen() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let model = rig.model
        model.setSpacing(20)
        model.cancel()
        #expect(model.confirmingDiscard)
        let isPresented = Binding(get: { model.confirmingDiscard }, set: { model.confirmingDiscard = $0 })
        // Cancel only closes the sheet.
        isPresented.wrappedValue = false
        #expect(rig.closed.count == 0)
        model.cancel()
        confirmThenClose(isPresented: isPresented) { model.discard() }()
        #expect(!model.confirmingDiscard)
        #expect(rig.closed.count == 1)
    }

    @Test func anExistingLayoutIsReplacedUnderItsOwnId() async throws {
        let rig = try await rig(isNew: false)
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let id = rig.model.layout.id
        rig.model.setSpacing(20)
        await rig.model.save()
        let stored = await rig.repository.userLayouts
        #expect(stored.map(\.id) == [id])
        #expect(stored[0].spacing == 20)
    }

    @Test func savingIsRefusedWhileTheNameOrLayoutIsInvalid() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        rig.model.setName("   ")
        #expect(!rig.model.canSave)
        await rig.model.save()
        #expect(await rig.repository.userLayouts.isEmpty)
        #expect(rig.closed.count == 0)
    }

    @Test func aFailedSaveKeepsTheEditorOpenAndSaysSo() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        // The directory is gone, so the write fails.
        try FileManager.default.removeItem(at: rig.directory)
        await rig.model.save()
        #expect(rig.model.saveError == .failed)
        #expect(rig.closed.count == 0)
        #expect(rig.model.isDirty || rig.model.isNew)
    }

    @Test func cancelClosesAtOnceWhenNothingChangedAndAsksWhenSomethingDid() async throws {
        let clean = try await rig(isNew: false)
        defer { try? FileManager.default.removeItem(at: clean.directory) }
        clean.model.cancel()
        #expect(clean.closed.count == 1)
        #expect(!clean.model.confirmingDiscard)

        let dirty = try await rig(isNew: false)
        defer { try? FileManager.default.removeItem(at: dirty.directory) }
        dirty.model.divide(zone: 1, axis: .vertical)
        dirty.model.cancel()
        #expect(dirty.closed.count == 0)
        #expect(dirty.model.confirmingDiscard)
        dirty.model.discard()
        #expect(dirty.closed.count == 1)
        // Nothing was written.
        #expect(await dirty.repository.userLayouts.first?.zones.count == 2)
    }

    @Test func switchingThePluginOffClosesACleanEditorAndAsksAboutChanges() async throws {
        let clean = try await rig(isNew: false)
        defer { try? FileManager.default.removeItem(at: clean.directory) }
        clean.model.pluginSwitchedOff()
        #expect(clean.closed.count == 1)

        let dirty = try await rig(isNew: false)
        defer { try? FileManager.default.removeItem(at: dirty.directory) }
        dirty.model.divide(zone: 1, axis: .vertical)
        dirty.model.pluginSwitchedOff()
        #expect(dirty.closed.count == 0)
        #expect(dirty.model.confirmingDiscard)
        #expect(dirty.model.pluginIsOff)
        // The library does not depend on the running plugin: saving still works, then the window closes.
        dirty.model.confirmingDiscard = false
        await dirty.model.save()
        #expect(dirty.closed.count == 1)
        #expect(await dirty.repository.userLayouts.first?.zones.count == 3)
    }

    @Test func theLivePreviewFollowsEveryEditOverTheChosenDisplay() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let first = rig.preview.shown.last
        #expect(first?.count == 1)
        #expect(first?[0].area == CGRect(x: 0, y: 0, width: 1600, height: 1000))
        #expect(first?[0].zones.map(\.number) == [1, 2])
        rig.model.divide(zone: 1, axis: .horizontal)
        #expect(rig.preview.shown.last?[0].zones.map(\.number) == [1, 2, 3])
        // Frames are the real ones on the display: spacing 8 around, so zone 1 starts at 8.
        #expect(rig.preview.shown.last?[0].zones.first?.frame.minX == 8)
        rig.model.tearDown()
        #expect(rig.preview.hidden >= 1)
    }

    @Test func theEditorPicksTheMainDisplayFirstAndCanSwitch() async throws {
        let displays = [
            DisplayInfo(id: 2, uuid: "B", frame: CGRect(x: 1600, y: 0, width: 1000, height: 1600)),
            DisplayInfo(id: 1, uuid: "A", frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), isMain: true),
        ]
        let rig = try await rig(displays: displays)
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        #expect(rig.model.displays.map(\.key) == ["A", "B"])
        #expect(rig.model.selectedDisplay?.key == "A")
        rig.model.selectDisplay("B")
        #expect(rig.preview.shown.last?[0].key == "B")
        #expect(rig.model.aspectRatio < 1)
    }

    @Test func aDragIsOneUndoStep() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let divider = DividerRef(axis: .vertical, index: 1)
        for share in stride(from: 0.5, through: 0.7, by: 0.02) { rig.model.dragDivider(divider, to: share) }
        rig.model.endDrag()
        #expect(abs(rig.model.position(of: divider) - 0.7) < 1e-6)
        rig.model.undo()
        #expect(abs(rig.model.position(of: divider) - 0.5) < 1e-6)
        #expect(!rig.model.canUndo)
        rig.model.redo()
        #expect(abs(rig.model.position(of: divider) - 0.7) < 1e-6)
    }

    @Test func aRefusedEditSaysWhyAndTheNextEditClearsIt() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        rig.model.merge()
        #expect(rig.model.message == GridEditorText.message(for: .nothingToMerge))
        rig.model.divide(zone: 1, axis: .horizontal)
        #expect(rig.model.message == nil)
        for failure in [
            EditorFailure.zoneLimit, .trackLimit, .tooNarrow, .notRectangle, .notAligned, .outerEdge, .badValue,
        ] {
            #expect(!GridEditorText.message(for: failure).isEmpty)
        }
    }

    @Test func tabLeavesTheCanvasAtTheEndsAndStaysInsideOtherwise() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        // Zone 1, zone 2, the one divider: Tab walks them and then lets focus go on to the next control.
        #expect(rig.model.focus == .zone(1))
        #expect(rig.model.handle(.tab))
        #expect(rig.model.focus == .zone(2))
        #expect(rig.model.handle(.tab))
        #expect(rig.model.focus == .divider(DividerRef(axis: .vertical, index: 1)))
        #expect(!rig.model.handle(.tab))
        #expect(rig.model.handle(.backTab))
        rig.model.focus(.zone(1))
        #expect(!rig.model.handle(.backTab))
        // Arrows on a zone mean nothing.
        #expect(!rig.model.handle(.left))
    }

    @Test func selectionFromTheListFeedsMerge() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        rig.model.setSelection([1, 2])
        #expect(rig.model.canMerge)
        rig.model.merge()
        #expect(rig.model.layout.zones.count == 1)
        #expect(rig.model.message == nil)
        rig.model.setSelection([42])
        #expect(rig.model.selection.isEmpty)
    }

    @Test func numericFieldsMoveDividersThroughTheModel() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        rig.model.setEdge(.right, ofZone: 1, percent: 25)
        #expect(rig.model.zoneRows[0].summary == "0 / 0 / 25 / 100")
        rig.model.setEdge(.left, ofZone: 1, percent: 10)
        #expect(rig.model.message == GridEditorText.message(for: .outerEdge))
    }
}

@MainActor @Suite struct GridEditorClosingTests {
    @MainActor private final class Preview: ZoneOverlayPresenting {
        var shows = 0
        func show(_ displays: [DragDisplay]) { shows += 1 }
        func highlight(_ zone: DragZone?) {}
        func hide() {}
    }

    private func make(_ preview: Preview, saveBlocked: Bool = false) -> GridEditorModel {
        let directory = FileManager.default.temporaryDirectory.appending(path: "lintel-closing-\(UUID().uuidString)")
        return GridEditorModel(
            layout: StockLayouts.layout(StockLayouts.columns2) ?? StockLayouts.all[0], isNew: true,
            repository: LayoutRepository(directory: directory),
            displays: {
                [DisplayInfo(id: 1, uuid: "A", frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), isMain: true)]
            },
            preview: preview)
    }

    @Test func aLateOpenAfterTearDownDrawsNothing() async {
        let preview = Preview()
        let model = make(preview)
        model.tearDown()
        await model.open()
        #expect(preview.shows == 0)
        model.divide(zone: 1, axis: .horizontal)
        model.dragDivider(DividerRef(axis: .vertical, index: 1), to: 0.7)
        #expect(preview.shows == 0)
        #expect(model.isClosed)
    }

    @Test func closingBySavingOrDiscardingStopsLaterDrawing() async {
        let preview = Preview()
        let model = make(preview)
        await model.open()
        let before = preview.shows
        model.divide(zone: 1, axis: .horizontal)
        #expect(preview.shows > before)
        model.discard()
        let after = preview.shows
        model.undo()
        #expect(preview.shows == after)
    }

    @Test func aDragClearsAnEarlierSaveError() async {
        let preview = Preview()
        let model = make(preview)
        await model.open()
        // The folder does not exist, so the write fails.
        await model.save()
        #expect(model.saveError == .failed)
        model.dragDivider(DividerRef(axis: .vertical, index: 1), to: 0.6)
        #expect(model.saveError == nil)
    }
}
