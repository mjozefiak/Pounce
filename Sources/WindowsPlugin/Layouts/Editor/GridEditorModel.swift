import CoreGraphics
import Foundation
import LintelKit
import Observation
import SwiftUI

/// The words of the editor that more than one place needs (the model, the view and the tests).
enum GridEditorText {
    /// "Zone 2, x 25%, y 0%, width 50%, height 100%": what VoiceOver reads for a zone and what the list shows.
    static func zoneDescription(number: Int, x: Int, y: Int, width: Int, height: Int) -> String {
        String(
            localized: "Zone \(number), x \(x)%, y \(y)%, width \(width)%, height \(height)%",
            comment: "Layout editor: a zone with its position and size as percentages of the display (spoken)")
    }

    static func zoneName(_ number: Int) -> String { ZoneOverlayText.zoneName(number) }

    static func message(for failure: EditorFailure) -> String {
        switch failure {
        case .unknownZone, .unknownDivider, .badValue:
            String(localized: "That value can’t be used.", comment: "Layout editor: a field got a value it refuses")
        case .zoneLimit:
            String(localized: "A layout can have at most 64 zones.", comment: "Layout editor: the zone limit")
        case .trackLimit:
            String(
                localized: "A layout can have at most 32 columns and 32 rows.",
                comment: "Layout editor: the track limit")
        case .tooNarrow:
            String(
                localized: "A zone can’t get any narrower.", comment: "Layout editor: a divider reached its limit")
        case .nothingToMerge:
            String(
                localized: "Select two or more zones to merge.", comment: "Layout editor: Merge needs a selection")
        case .notRectangle:
            String(
                localized: "Those zones don’t make one rectangle, so they can’t be merged.",
                comment: "Layout editor: the selected zones cannot be merged")
        case .notAligned:
            String(
                localized: "The zones on both sides of this divider don’t line up. Select them and choose Merge.",
                comment: "Layout editor: Delete on a divider is refused")
        case .outerEdge:
            String(
                localized: "The border of the display can’t be moved.",
                comment: "Layout editor: an outer edge was edited")
        case .nothingToUndo:
            String(localized: "Nothing to undo.", comment: "Layout editor: Undo without history")
        case .nothingToRedo:
            String(localized: "Nothing to redo.", comment: "Layout editor: Redo without history")
        }
    }
}

/// One display the preview can be shown on.
struct EditorDisplay: Identifiable, Equatable {
    var key: String
    var title: String
    var area: CGRect
    var id: String { key }
}

/// The editor of one layout (spec: UI/UX, "Layout editors"): the pure `GridEditorState`, the live preview over the
/// chosen display, saving through the repository and the questions on the way out. It holds no window; the
/// controller owns that and the view reads this.
@MainActor @Observable
final class GridEditorModel {
    enum SaveError: Equatable {
        case readOnly
        case failed
        case invalid
    }

    private(set) var state: GridEditorState
    /// The layout is new: *Save* adds it to the library, otherwise it replaces the one with the same id.
    let isNew: Bool
    private(set) var displays: [EditorDisplay] = []
    var selectedDisplayKey: String?
    /// The last refusal or failure, in words; cleared by the next edit.
    private(set) var message: String?
    private(set) var saveError: SaveError?
    private(set) var isSaving = false
    /// Cancel or close with unsaved changes asks first.
    var confirmingDiscard = false
    /// The plugin was switched off: the question changes (there is nothing to go back to) and the window closes
    /// after it.
    private(set) var pluginIsOff = false
    @ObservationIgnored private var dragStart: GridEditorState?
    /// The editor was closed: a late `open()` or edit must not draw the preview again.
    @ObservationIgnored private(set) var isClosed = false

    @ObservationIgnored private let repository: LayoutRepository
    @ObservationIgnored private let loadDisplays: () async -> [DisplayInfo]
    @ObservationIgnored private let preview: any ZoneOverlayPresenting
    @ObservationIgnored private let announce: (String) -> Void
    @ObservationIgnored private let onSaved: (GridLayout) -> Void
    @ObservationIgnored private let onClose: () -> Void

    init(
        layout: GridLayout, isNew: Bool, repository: LayoutRepository,
        displays: @escaping () async -> [DisplayInfo], preview: any ZoneOverlayPresenting,
        announce: @escaping (String) -> Void = { _ in }, onSaved: @escaping (GridLayout) -> Void = { _ in },
        onClose: @escaping () -> Void = {}
    ) {
        state = GridEditorState(layout)
        self.isNew = isNew
        self.repository = repository
        loadDisplays = displays
        self.preview = preview
        self.announce = announce
        self.onSaved = onSaved
        self.onClose = onClose
    }

    // MARK: Reading

    var layout: GridLayout { state.layout }
    var isDirty: Bool { state.isDirty }
    var canUndo: Bool { state.canUndo }
    var canRedo: Bool { state.canRedo }
    var canMerge: Bool { state.selection.count >= 2 }
    var canSave: Bool { state.canSave && !isSaving && !(state.isDirty == false && !isNew) }
    var nameIsValid: Bool { LayoutRules.isValidName(state.layout.name) }
    var selection: Set<Int> { state.selection }
    var focus: EditorFocus? { state.focus }

    var selectedDisplay: EditorDisplay? { displays.first { $0.key == selectedDisplayKey } ?? displays.first }

    /// The shape of the preview: the display's, or 16:10 when there is none.
    var aspectRatio: CGFloat {
        guard let area = selectedDisplay?.area, area.width > 0, area.height > 0 else { return 16.0 / 10.0 }
        return area.width / area.height
    }

    struct ZoneRow: Identifiable, Equatable {
        var id: Int
        var number: Int
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        /// "0 / 0 / 50 / 100", as the list shows it.
        var summary: String { "\(x) / \(y) / \(width) / \(height)" }
        var spoken: String { GridEditorText.zoneDescription(number: number, x: x, y: y, width: width, height: height) }
    }

    var zoneRows: [ZoneRow] {
        state.layout.zones.enumerated().compactMap { index, zone in
            guard let p = state.percentages(ofZone: zone.id) else { return nil }
            return ZoneRow(id: zone.id, number: index + 1, x: p.x, y: p.y, width: p.width, height: p.height)
        }
    }

    /// The zone's rectangle as shares of the preview (for drawing).
    func rect(ofZone id: Int) -> CGRect? { state.rect(ofZone: id) }
    var dividers: [DividerRef] { state.dividers }
    func position(of divider: DividerRef) -> Double { state.position(of: divider) ?? 0 }

    func dividerDescription(_ divider: DividerRef) -> String {
        let percent = Int((position(of: divider) * 100).rounded())
        return divider.axis == .vertical
            ? String(
                localized: "Vertical divider at \(percent)%",
                comment: "Layout editor: a divider between columns, its position as a percentage (spoken)")
            : String(
                localized: "Horizontal divider at \(percent)%",
                comment: "Layout editor: a divider between rows, its position as a percentage (spoken)")
    }

    // MARK: Lifecycle

    func open() async {
        guard !isClosed else { return }
        let infos = await loadDisplays()
        guard !isClosed else { return }
        let keyed = DisplayKeys.keys(for: infos)
        let ordered = infos.sorted {
            if $0.isMain != $1.isMain { return $0.isMain }
            return ($0.frame.minX, $0.frame.minY, $0.id) < ($1.frame.minX, $1.frame.minY, $1.id)
        }
        displays = ordered.enumerated().map { index, info in
            EditorDisplay(
                key: keyed.keys[info.id] ?? info.uuid,
                title: info.isMain
                    ? String(localized: "Main display", comment: "Layouts window: the display with the menu bar")
                    : String(localized: "Display \(index + 1)", comment: "Layouts window: a display, by number"),
                area: info.visibleFrame)
        }
        if selectedDisplay == nil { selectedDisplayKey = nil } else { selectedDisplayKey = selectedDisplay?.key }
        refreshPreview()
    }

    /// Releases the preview panel (the window is closing).
    func tearDown() {
        isClosed = true
        preview.hide()
    }

    // MARK: Preview

    /// Redraws the live preview over the chosen display from the layout as it is now.
    func refreshPreview() {
        guard !isClosed else { return }
        guard let display = selectedDisplay, state.layout.isValid else {
            preview.hide()
            return
        }
        let frames = state.layout.frames(in: display.area)
        let zones = state.layout.zones.enumerated().compactMap { index, zone -> DragZone? in
            frames[zone.id].map { DragZone(displayKey: display.key, zoneID: zone.id, number: index + 1, frame: $0) }
        }
        preview.show([DragDisplay(key: display.key, area: display.area, zones: zones)])
        if case .zone(let id)? = state.focus, let focused = zones.first(where: { $0.zoneID == id }) {
            preview.highlight(focused)
        } else {
            preview.highlight(nil)
        }
    }

    func selectDisplay(_ key: String) {
        selectedDisplayKey = key
        refreshPreview()
    }

    // MARK: Editing

    /// Runs an edit: a refusal is said in words (and announced), a success clears the last message.
    @discardableResult
    private func edit(_ body: (inout GridEditorState) -> Result<Void, EditorFailure>?) -> Bool {
        saveError = nil
        guard let result = body(&state) else { return false }
        switch result {
        case .success:
            message = nil
        case .failure(let failure):
            let text = GridEditorText.message(for: failure)
            message = text
            announce(text)
        }
        refreshPreview()
        if case .success = result { return true }
        return false
    }

    func setName(_ name: String) {
        edit {
            $0.setName(name)
            return .success(())
        }
    }
    func setSpacing(_ points: Int) { edit { $0.setSpacing(points) } }
    func divide(zone id: Int, axis: EditorAxis, share: Double = 0.5) {
        edit { $0.divide(zone: id, axis: axis, share: share) }
    }
    func divideFocused(axis: EditorAxis) {
        guard case .zone(let id)? = state.focus ?? state.layout.zones.first.map({ .zone($0.id) }) else { return }
        divide(zone: id, axis: axis)
    }
    func merge() { edit { $0.mergeSelection() } }
    func undo() { edit { $0.undo() } }
    func redo() { edit { $0.redo() } }
    func removeDivider(_ divider: DividerRef) { edit { $0.removeDivider(divider) } }
    func setEdge(_ edge: GridEditorState.ZoneEdge, ofZone id: Int, percent: Int) {
        edit { $0.setEdge(edge, ofZone: id, to: Double(percent) / 100) }
    }

    func nudge(_ divider: DividerRef, by delta: Double) { edit { $0.moveDivider(divider, by: delta) } }

    func setSelection(_ ids: Set<Int>) {
        state.selection = ids.intersection(state.layout.zones.map(\.id))
        if let first = state.layout.zones.first(where: { state.selection.contains($0.id) }) {
            state.focus = .zone(first.id)
        }
        refreshPreview()
    }

    func toggleSelection(zone id: Int) {
        state.toggleSelection(zone: id)
        state.focus = .zone(id)
        refreshPreview()
    }

    func focus(_ focus: EditorFocus) {
        state.focus = focus
        refreshPreview()
    }

    // MARK: Dragging a divider

    /// A drag is one undo step however many events it sends: every event starts from the layout before it.
    func dragDivider(_ divider: DividerRef, to share: Double) {
        guard !isClosed else { return }
        saveError = nil
        if dragStart == nil { dragStart = state }
        guard var next = dragStart else { return }
        _ = next.moveDivider(divider, to: share)
        next.focus = .divider(divider)
        state = next
        message = nil
        refreshPreview()
    }

    func endDrag() { dragStart = nil }

    // MARK: Keys

    /// Whether the canvas used a key (`false`: it means nothing here, or Tab would leave the canvas).
    @discardableResult
    func handle(_ key: EditorKey) -> Bool {
        if key == .tab || key == .backTab {
            let order = state.focusOrder
            let atEnd = key == .tab ? state.focus == order.last : state.focus == order.first
            if atEnd, state.focus != nil, order.count > 1 { return false }
        }
        var consumed = false
        edit {
            let result = $0.handle(key)
            consumed = result != nil
            return result
        }
        return consumed
    }

    // MARK: Saving and leaving

    func save() async {
        guard state.canSave, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            var toSave = state.layout
            toSave.name = toSave.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let stored: GridLayout
            if isNew {
                stored = try await repository.create(toSave)
            } else {
                try await repository.replace(toSave)
                stored = toSave
            }
            saveError = nil
            onSaved(stored)
            close()
        } catch let error as LayoutRepository.RepositoryError {
            saveError = error == .readOnly ? .readOnly : (error == .write ? .failed : .invalid)
        } catch {
            saveError = .failed
        }
    }

    /// Cancel and Esc: asks first when there is something to lose.
    func cancel() {
        if state.isDirty {
            confirmingDiscard = true
        } else {
            close()
        }
    }

    func discard() {
        confirmingDiscard = false
        close()
    }

    /// The window's close button and the plugin switching off ask the same question.
    var needsDiscardPrompt: Bool { state.isDirty && !confirmingDiscard }

    /// The plugin was switched off. A clean editor closes at once; one with changes asks first (save or discard).
    func pluginSwitchedOff() {
        pluginIsOff = true
        if state.isDirty {
            confirmingDiscard = true
        } else {
            close()
        }
    }

    private func close() {
        isClosed = true
        preview.hide()
        onClose()
    }
}
