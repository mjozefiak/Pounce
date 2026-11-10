import AppKit
import LintelUI
import SwiftUI

/// The grid editor window's content (mockup 03): a sidebar with the name, the space around zones and the zone
/// list (the accessible representation of the preview, with numeric fields), and the canvas with the zones and
/// their dividers. The layout of the sidebar and the canvas follows the mockup; colours are the brand's warm
/// neutrals and type follows the app's text size.
struct GridEditorView: View {
    @Bindable var model: GridEditorModel
    @Environment(\.lintelTextSize) private var textSize
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool
    @FocusState private var canvasFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 310)
                .background(LintelBrand.sidebarBackground)
            LintelDivider(axis: .vertical)
            previewColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LintelBrand.windowBackground)
        }
        .frame(minWidth: 880, minHeight: 580)
        .task {
            nameDraft = model.layout.name
            await model.open()
        }
        .onChange(of: model.layout.name) { _, name in if !nameFocused { nameDraft = name } }
        .destructiveConfirmation(isPresented: $model.confirmingDiscard, Self.discardConfirmation) {
            model.discard()
        }
    }

    static let discardConfirmation = DestructiveConfirmation(
        prompt: LocalizedStringResource(
            "Discard your changes to this layout?", comment: "Layout editor: asked when closing with unsaved changes"),
        detail: LocalizedStringResource(
            "This can’t be undone.", comment: "Confirmation sheet: the consequence line of a destructive action"),
        confirmTitle: LocalizedStringResource("Discard", comment: "Layout editor: the button that drops the changes"))

    private func commitName() {
        if nameDraft != model.layout.name { model.setName(nameDraft) }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if model.isNew {
                    Text("New layout", comment: "Layout editor: the title while a layout is being made")
                } else {
                    Text("Edit layout", comment: "Layout editor: the title while a layout is being changed")
                }
            }
            .font(textSize.font(.title3, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
            nameField
            Text("Style: Grid", comment: "Layout editor: the style of the layout being edited")
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.secondaryText)
            spacingRow
            zonesSection
            toolRow
            Spacer(minLength: 0)
            if model.pluginIsOff {
                Text(
                    "Window Management is off. Save or discard your changes to close this window.",
                    comment: "Layout editor: the plugin was switched off while the editor had unsaved changes"
                )
                .font(textSize.font(.caption1))
                .foregroundStyle(LintelBrand.secondaryText)
            }
            if let error = model.saveError {
                Text(saveErrorText(error)).font(textSize.font(.caption1)).foregroundStyle(LintelBrand.statusError)
            }
            footer
        }
        .padding(20)
    }

    private func saveErrorText(_ error: GridEditorModel.SaveError) -> LocalizedStringResource {
        switch error {
        case .readOnly:
            LocalizedStringResource(
                "These layouts were saved by a newer version of Lintel and can’t be changed here.",
                comment: "Layout editor: saving is refused because the library file is newer")
        case .failed:
            LocalizedStringResource(
                "The layout could not be saved. Your other layouts are unchanged.",
                comment: "Layout editor: the file could not be written")
        case .invalid:
            LocalizedStringResource(
                "This layout can’t be saved. Check the name and the zones.",
                comment: "Layout editor: the layout breaks a rule")
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name", comment: "Layout editor: the field that names the layout")
                .font(textSize.font(.caption1, weight: .semibold))
                .foregroundStyle(LintelBrand.secondaryText)
            TextField(text: $nameDraft) {
                Text("Name", comment: "Layout editor: the field that names the layout")
            }
            .textFieldStyle(.roundedBorder)
            .focused($nameFocused)
            .onSubmit(commitName)
            .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
            .accessibilityLabel(Text("Layout name", comment: "Layout editor: the name field (spoken)"))
            if !LayoutRules.isValidName(nameDraft) {
                Text(
                    "Use 1 to 64 characters, without control characters.",
                    comment: "Layout editor: the name is empty, too long or has forbidden characters"
                )
                .font(textSize.font(.caption1))
                .foregroundStyle(LintelBrand.statusError)
            }
        }
    }

    private var spacingRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Space around zones", comment: "Layout editor: the gap between zones and around them")
                .font(textSize.font(.caption1, weight: .semibold))
                .foregroundStyle(LintelBrand.secondaryText)
            HStack(spacing: 8) {
                Button {
                    model.setSpacing(model.layout.spacing - 1)
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(model.layout.spacing <= 0)
                .accessibilityLabel(Text("Less space", comment: "Layout editor: decreases the space around zones"))
                Text("\(model.layout.spacing) px", comment: "Layout editor: the space around zones in points")
                    .font(textSize.font(.body))
                    .monospacedDigit()
                    .frame(minWidth: 52)
                    .accessibilityLabel(
                        Text(
                            "Space around zones: \(model.layout.spacing) points",
                            comment: "Layout editor: the space around zones (spoken)"))
                Button {
                    model.setSpacing(model.layout.spacing + 1)
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(model.layout.spacing >= GridLayout.maximumSpacing)
                .accessibilityLabel(Text("More space", comment: "Layout editor: increases the space around zones"))
            }
            .controlSize(.small)
        }
    }

    // MARK: Zone list

    private var zonesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Zones", comment: "Layout editor: the heading of the zone list")
                .font(textSize.font(.caption1, weight: .semibold))
                .foregroundStyle(LintelBrand.secondaryText)
                .accessibilityAddTraits(.isHeader)
            List(
                selection: Binding(get: { model.selection }, set: { model.setSelection($0) })
            ) {
                ForEach(model.zoneRows) { row in
                    HStack {
                        Text(GridEditorText.zoneName(row.number)).font(textSize.font(.body))
                        Spacer()
                        Text(verbatim: row.summary)
                            .font(textSize.font(.callout))
                            .monospacedDigit()
                            .foregroundStyle(LintelBrand.secondaryText)
                    }
                    .tag(row.id)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: row.spoken))
                    .accessibilityAddTraits(model.selection.contains(row.id) ? .isSelected : [])
                    .accessibilityAction(named: Text("Divide side by side", comment: "Layout editor: divides a zone")) {
                        model.divide(zone: row.id, axis: .vertical)
                    }
                    .accessibilityAction(named: Text("Divide stacked", comment: "Layout editor: divides a zone")) {
                        model.divide(zone: row.id, axis: .horizontal)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 110, maxHeight: 170)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LintelBrand.card))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(LintelBrand.hairline))
            if let row = focusedRow { fields(for: row) }
        }
    }

    private var focusedRow: GridEditorModel.ZoneRow? {
        guard case .zone(let id)? = model.focus else { return nil }
        return model.zoneRows.first { $0.id == id }
    }

    /// The numeric fields of the focused zone: every move of an edge has a keyboard and VoiceOver path.
    private func fields(for row: GridEditorModel.ZoneRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: row.spoken).font(textSize.font(.caption1)).foregroundStyle(LintelBrand.secondaryText)
            HStack(spacing: 6) {
                field("x", value: row.x) { model.setEdge(.left, ofZone: row.id, percent: $0) }
                field("y", value: row.y) { model.setEdge(.top, ofZone: row.id, percent: $0) }
                field("width", value: row.width) { model.setEdge(.right, ofZone: row.id, percent: row.x + $0) }
                field("height", value: row.height) { model.setEdge(.bottom, ofZone: row.id, percent: row.y + $0) }
            }
        }
    }

    private func field(_ name: LocalizedStringResource, value: Int, set: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(textSize.font(.caption2)).foregroundStyle(LintelBrand.secondaryText)
            TextField(
                value: Binding(get: { value }, set: { set($0) }), format: .number
            ) {
                Text(name)
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel(Text(name))
            .accessibilityValue(Text("\(value)%", comment: "Layout editor: a percentage (spoken)"))
        }
    }

    private var toolRow: some View {
        HStack(spacing: 8) {
            Button {
                model.merge()
            } label: {
                Text("Merge", comment: "Layout editor: merges the selected zones")
            }
            .disabled(!model.canMerge)
            Button {
                model.divideFocused(axis: .vertical)
            } label: {
                Text("Divide", comment: "Layout editor: divides the focused zone")
            }
            Button {
                model.undo()
            } label: {
                Text("Undo", comment: "Layout editor: takes the last change back")
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!model.canUndo)
            Button {
                model.redo()
            } label: {
                Text("Redo", comment: "Layout editor: does the change that was taken back again")
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!model.canRedo)
        }
        .controlSize(.small)
    }

    private var footer: some View {
        HStack {
            Button {
                model.cancel()
            } label: {
                HStack(spacing: 6) {
                    Text("Cancel", comment: "Layout editor: closes the editor")
                    Text("Esc", comment: "Layout editor: the key of Cancel").font(textSize.font(.caption2))
                        .foregroundStyle(LintelBrand.secondaryText)
                }
            }
            .buttonStyle(LintelSecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button {
                commitName()
                model.actions.enqueue { await model.save() }
            } label: {
                HStack(spacing: 6) {
                    Text("Save", comment: "Layout editor: saves the layout and closes the editor")
                    Text("⌘S", comment: "Layout editor: the key of Save").font(textSize.font(.caption2))
                }
            }
            .buttonStyle(LintelPrimaryButtonStyle())
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!model.canSave)
        }
    }

    // MARK: Preview

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preview", comment: "Layout editor: the heading above the canvas")
                    .font(textSize.font(.headline))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if model.displays.count > 1 { displayPicker }
            }
            canvas
            Text(
                "Click a zone to divide it, ⇧-click to divide it the other way, ⌘-click to select it for Merge. Drag a divider to move it. Tab moves between zones and dividers · S divides · arrows move a divider by 1% · Delete on a divider merges its neighbours.",
                comment: "Layout editor: how to use the canvas"
            )
            .font(textSize.font(.caption1))
            .foregroundStyle(LintelBrand.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            if let message = model.message {
                Text(verbatim: message).font(textSize.font(.callout)).foregroundStyle(LintelBrand.statusError)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(20)
    }

    private var displayPicker: some View {
        Menu {
            ForEach(model.displays) { display in
                Button {
                    model.selectDisplay(display.key)
                } label: {
                    if display.key == model.selectedDisplay?.key {
                        Label(display.title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: display.title)
                    }
                }
            }
        } label: {
            Text(verbatim: model.selectedDisplay?.title ?? "")
        }
        .menuStyle(.button)
        .fixedSize()
        .accessibilityLabel(Text("Preview display", comment: "Layout editor: the display the live preview is shown on"))
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let size = fitted(in: proxy.size)
            canvasContent(size: size)
                .frame(width: size.width, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func fitted(in available: CGSize) -> CGSize {
        let ratio = model.aspectRatio
        guard available.width > 0, available.height > 0 else { return .zero }
        if available.width / available.height > ratio {
            return CGSize(width: available.height * ratio, height: available.height)
        }
        return CGSize(width: available.width, height: available.width / ratio)
    }

    private func canvasContent(size: CGSize) -> some View {
        let area = model.selectedDisplay?.area
        let scale = area.map { $0.width > 0 ? size.width / $0.width : 1 } ?? 1
        var scaled = model.layout
        scaled.spacing = Int((Double(scaled.spacing) * Double(scale)).rounded())
        let frames = scaled.frames(in: CGRect(origin: .zero, size: size))
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LintelBrand.fill)
            ForEach(Array(model.layout.zones.enumerated()), id: \.element.id) { index, zone in
                if let frame = frames[zone.id] { zoneView(zone.id, number: index + 1, frame: frame) }
            }
            ForEach(model.dividers, id: \.self) { divider in dividerView(divider, size: size) }
        }
        .coordinateSpace(name: "canvas")
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(LintelBrand.hairline))
        .focusable()
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onKeyPress(phases: [.down, .repeat]) { press in
            guard let key = Self.editorKey(for: press) else { return .ignored }
            return model.handle(key) ? .handled : .ignored
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(
                "Layout preview. Use the zone list to change zones.",
                comment: "Layout editor: the canvas (spoken); the zone list is the accessible way to edit")
        )
    }

    /// The keyboard table of the canvas.
    static func editorKey(for press: KeyPress) -> EditorKey? {
        editorKey(key: press.key, characters: press.characters, modifiers: press.modifiers)
    }

    /// The table on plain values (a `KeyPress` cannot be built in a test).
    static func editorKey(key: KeyEquivalent, characters: String, modifiers: EventModifiers) -> EditorKey? {
        guard !modifiers.contains(.command), !modifiers.contains(.control) else { return nil }
        if DeleteKeys.isDelete(key: key, characters: characters) { return .delete }
        switch key {
        case .tab: return modifiers.contains(.shift) ? .backTab : .tab
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .upArrow: return .up
        case .downArrow: return .down
        case .space: return .toggleSelection
        default:
            switch characters.lowercased() {
            case "s": return modifiers.contains(.shift) ? .divideOther : .divide
            case "m": return .merge
            default: return nil
            }
        }
    }

    private func zoneView(_ id: Int, number: Int, frame: CGRect) -> some View {
        let selected = model.selection.contains(id)
        let focused = model.focus == .zone(id)
        return ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(selected ? LintelBrand.accent.opacity(0.55) : Color.white.opacity(0.35))
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(
                    focused || selected ? LintelBrand.accent : Color.white.opacity(0.8), lineWidth: focused ? 3 : 1.5)
            Text(verbatim: "\(number)")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color(white: ZoneOverlayStyle.pillGray)))
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture().onEnded { tap in
                canvasFocused = true
                let flags = NSEvent.modifierFlags
                if flags.contains(.command) {
                    model.toggleSelection(zone: id)
                } else if flags.contains(.shift) {
                    model.divide(
                        zone: id, axis: .horizontal,
                        share: Self.snapped(Self.localShare(tap.location, in: frame, axis: .horizontal)),
                        minimumHalf: GridEditorState.minimumClickShare)
                } else {
                    model.divide(
                        zone: id, axis: .vertical,
                        share: Self.snapped(Self.localShare(tap.location, in: frame, axis: .vertical)),
                        minimumHalf: GridEditorState.minimumClickShare)
                }
            }
        )
        .accessibilityHidden(true)
    }

    /// Where a click is across its zone, 0 to 1. The gesture sits on the view after `.position`, so the location is in
    /// the canvas's space, not the zone's: the zone's own origin comes off first (QA: a click at 79 % across zone 2
    /// divided it at 95 %, because the canvas x was divided by the zone's width).
    static func localShare(_ location: CGPoint, in frame: CGRect, axis: EditorAxis) -> Double {
        let share =
            axis == .vertical
            ? (location.x - frame.minX) / max(frame.width, 1) : (location.y - frame.minY) / max(frame.height, 1)
        return min(max(share, 0), 1)
    }

    /// A click near the middle divides exactly in half.
    static func snapped(_ share: Double) -> Double { abs(share - 0.5) < 0.04 ? 0.5 : share }

    private func dividerView(_ divider: DividerRef, size: CGSize) -> some View {
        let position = model.position(of: divider)
        let focused = model.focus == .divider(divider)
        let vertical = divider.axis == .vertical
        return ZStack {
            Color.clear
            Capsule()
                .fill(Color.white)
                .overlay(
                    Capsule().strokeBorder(
                        focused ? LintelBrand.accent : LintelBrand.hairline, lineWidth: focused ? 3 : 1)
                )
                .frame(width: vertical ? 8 : 44, height: vertical ? 44 : 8)
        }
        .frame(width: vertical ? 16 : size.width, height: vertical ? size.height : 16)
        .contentShape(Rectangle())
        .position(
            x: vertical ? position * size.width : size.width / 2, y: vertical ? size.height / 2 : position * size.height
        )
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                .onChanged { value in
                    canvasFocused = true
                    let share =
                        vertical ? value.location.x / max(size.width, 1) : value.location.y / max(size.height, 1)
                    model.dragDivider(divider, to: min(max(share, 0), 1))
                }
                .onEnded { _ in model.endDrag() }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: model.dividerDescription(divider)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.nudge(divider, by: GridEditorState.step)
            case .decrement: model.nudge(divider, by: -GridEditorState.step)
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("Merge neighbours", comment: "Layout editor: removes a divider")) {
            model.removeDivider(divider)
        }
    }
}
