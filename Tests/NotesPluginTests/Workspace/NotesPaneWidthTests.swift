import CoreGraphics
import Foundation
import Testing

@testable import NotesPlugin

@Suite("Notes pane widths (pure)")
struct NotesPaneLayoutTests {
    private func clamp(
        _ width: CGFloat, _ pane: NotesPane, scale: CGFloat = 1, section: CGFloat = 1600, other: CGFloat = 0
    ) -> CGFloat {
        NotesPaneLayout.clamp(
            width, pane: pane, textScale: scale, sectionWidth: section, otherWidth: other,
            reserve: NotesPaneLayout.centreReserve(textScale: scale))
    }

    @Test("the defaults are the widths the panes always had")
    func defaults() {
        #expect(NotesPaneLayout.defaultWidth(.explorer, textScale: 1) == 237.5)
        #expect(NotesPaneLayout.defaultWidth(.inspector, textScale: 1) == 287.5)
        #expect(NotesPaneLayout.defaultWidth(.explorer, textScale: 1.5) == 250)
        #expect(NotesPaneLayout.defaultWidth(.inspector, textScale: 1.5) == 300)
    }

    @Test("a width stays between the minimum and the maximum")
    func limits() {
        #expect(clamp(10, .explorer) == 180)
        #expect(clamp(10, .inspector) == 240)
        #expect(clamp(9999, .explorer) == 420)
        #expect(clamp(9999, .inspector) == 520)
        #expect(clamp(300, .explorer) == 300)
    }

    @Test("the minimum shrinks with a small text size and never grows with a large one")
    func minimumFollowsTheTextSize() {
        #expect(NotesPaneLayout.minimumWidth(.explorer, textScale: 0.8) == 144)
        #expect(NotesPaneLayout.minimumWidth(.explorer, textScale: 1.6) == 180)
    }

    @Test("the centre keeps its room: the other pane and the reserve come off what the pane may take")
    func centreKeepsItsRoom() {
        // 900 - 300 (inspector) - 420 (centre) = 180 for the explorer.
        #expect(clamp(400, .explorer, section: 900, other: 300) == 180)
        // The centre needs more room at a larger text size.
        #expect(clamp(400, .explorer, scale: 1.3, section: 1100, other: 300) == 254)
        // A section too narrow for the minimum still gives the minimum.
        #expect(clamp(400, .explorer, section: 500, other: 300) == 180)
        // Plenty of room: only the maximum applies.
        #expect(clamp(400, .explorer, section: 2000, other: 300) == 400)
    }

    @Test("an unmeasured section (infinite width) and a bad request are handled")
    func oddInputs() {
        #expect(clamp(300, .explorer, section: .infinity) == 300)
        #expect(clamp(.nan, .explorer) == 237.5)
        #expect(clamp(.infinity, .inspector) == 287.5)
    }

    @Test("the stored width wins over the default, and is kept inside the limits")
    func effective() {
        func width(_ stored: CGFloat?) -> CGFloat {
            NotesPaneLayout.effectiveWidth(
                .explorer, stored: stored, textScale: 1, sectionWidth: 1600, otherWidth: 0, reserve: 420)
        }
        #expect(width(nil) == 237.5)
        #expect(width(300) == 300)
        #expect(width(5) == 180)
    }

    @Test("dragging the explorer's divider right widens it; the inspector's divider is on its left edge")
    func dragDirection() {
        #expect(NotesPaneLayout.dragged(from: 250, translation: 30, pane: .explorer) == 280)
        #expect(NotesPaneLayout.dragged(from: 250, translation: -30, pane: .explorer) == 220)
        #expect(NotesPaneLayout.dragged(from: 300, translation: 30, pane: .inspector) == 270)
        #expect(NotesPaneLayout.dragged(from: 300, translation: -30, pane: .inspector) == 330)
    }

    @Test("stored integers: 0 or less is the default; widths are stored in whole points")
    func storage() {
        #expect(NotesPaneLayout.stored(0) == nil)
        #expect(NotesPaneLayout.stored(-4) == nil)
        #expect(NotesPaneLayout.stored(310) == 310)
        #expect(NotesPaneLayout.raw(310.6) == 311)
        #expect(NotesPaneLayout.raw(.nan) == 0)
        #expect(NotesPaneLayout.raw(-5) == 0)
    }
}

@MainActor
@Suite("Notes pane widths (model)")
struct NotesPaneWidthModelTests {
    private func model(_ harness: NotesHarness? = nil) -> NotesWorkspaceModel {
        var environment = NotesWorkspaceModel.Environment(
            library: NoteLibrary(box: SourceBox([])), pasteboard: RecordingPasteboard())
        environment.preferences = harness.map { NoteViewPreferences(settings: $0.settings) }
        return NotesWorkspaceModel(environment: environment)
    }

    @Test("with nothing stored the panes have their default widths")
    func defaults() {
        let model = model()
        model.sectionWidth = 1600
        #expect(model.paneWidth(.explorer, textScale: 1) == 237.5)
        #expect(model.paneWidth(.inspector, textScale: 1) == 287.5)
    }

    @Test("a drag shows the width at once and stores nothing until it ends; the end stores whole points")
    func dragThenEnd() throws {
        let harness = try NotesHarness()
        let model = model(harness)
        model.sectionWidth = 1600
        model.dragPane(.explorer, from: 237.5, translation: 62.4, textScale: 1)
        #expect(model.paneWidth(.explorer, textScale: 1) == 299.9)
        #expect(harness.notesSettings.explorerWidth == 0)
        model.endPaneDrag(textScale: 1)
        #expect(model.paneDrag == nil)
        #expect(harness.notesSettings.explorerWidth == 300)
        #expect(model.paneWidth(.explorer, textScale: 1) == 300)
        // The next launch reads it back.
        let again = NoteViewPreferences(settings: harness.settings)
        #expect(again.explorerWidth == 300)
    }

    @Test("a drag past a limit stops at the limit")
    func dragIsClamped() {
        let model = model()
        model.sectionWidth = 1600
        model.dragPane(.inspector, from: 300, translation: 5000, textScale: 1)
        #expect(model.paneWidth(.inspector, textScale: 1) == 240)
        model.dragPane(.inspector, from: 300, translation: -5000, textScale: 1)
        #expect(model.paneWidth(.inspector, textScale: 1) == 520)
        model.endPaneDrag(textScale: 1)
        #expect(model.preferences.inspectorWidth == 520)
    }

    @Test("a double-click goes back to the default and stores the default")
    func reset() throws {
        let harness = try NotesHarness()
        let model = model(harness)
        model.sectionWidth = 1600
        model.setPaneWidth(.explorer, to: 380, textScale: 1)
        #expect(harness.notesSettings.explorerWidth == 380)
        model.resetPaneWidth(.explorer, textScale: 1)
        #expect(harness.notesSettings.explorerWidth == 0)
        #expect(model.paneWidth(.explorer, textScale: 1) == 237.5)
    }

    @Test("hiding the inspector keeps its width for when it comes back")
    func hidingKeepsTheWidth() {
        let model = model()
        model.sectionWidth = 1600
        model.setPaneWidth(.inspector, to: 400, textScale: 1)
        model.setInspectorVisible(false)
        model.setInspectorVisible(true)
        #expect(model.paneWidth(.inspector, textScale: 1) == 400)
    }

    @Test("the inspector cannot be dragged so wide that the centre loses its room, so it keeps fitting")
    func widthsKeepTheFit() {
        let model = model()
        model.updateInspectorFit(sectionWidth: 1100, textScale: 1)
        #expect(model.inspectorVisible)
        // 1100 - 250 (explorer) - 420 (centre) = 430.
        model.setPaneWidth(.inspector, to: 500, textScale: 1)
        #expect(model.paneWidth(.inspector, textScale: 1) == 430)
        #expect(model.inspectorVisible)
        // A narrower window then hides it, because 250 + 430 + 420 no longer fits.
        model.updateInspectorFit(sectionWidth: 1000, textScale: 1)
        #expect(!model.inspectorVisible)
    }

    @Test("the explorer cannot take the centre's room while the inspector sits beside the document")
    func centreIsProtected() async throws {
        let model = model()
        model.sectionWidth = 1100
        model.setPaneWidth(.explorer, to: 400, textScale: 1)
        // Without an open note there is no inspector in the layout, so only the reserve applies: 1100 - 420.
        #expect(model.paneWidth(.explorer, textScale: 1) == 400)
        #expect(model.paneWidth(.explorer, textScale: 1) + 420 <= 1100)
    }

    @Test("nudging by steps moves a pane by 16 points and stays inside the limits")
    func nudge() {
        let model = model()
        model.sectionWidth = 1600
        model.setPaneWidth(.explorer, to: 300, textScale: 1)
        model.nudgePane(.explorer, by: 1, textScale: 1)
        #expect(model.paneWidth(.explorer, textScale: 1) == 316)
        model.nudgePane(.explorer, by: -100, textScale: 1)
        #expect(model.paneWidth(.explorer, textScale: 1) == 180)
    }

    @Test("a drag never goes through an animation: the dividers and panes switch them off")
    func noAnimationDuringDrag() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let divider = try String(
            contentsOf: root.appending(path: "Sources/NotesPlugin/UI/Panes/NotesPaneDivider.swift"), encoding: .utf8)
        let section = try String(
            contentsOf: root.appending(path: "Sources/NotesPlugin/UI/NotesSectionView.swift"), encoding: .utf8)
        #expect(divider.contains("$0.animation = nil"))
        #expect(section.contains("$0.animation = nil"))
        #expect(!divider.contains("withAnimation"))
    }
}
