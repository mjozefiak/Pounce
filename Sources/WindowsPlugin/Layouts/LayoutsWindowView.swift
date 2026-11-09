import AppKit
import LintelUI
import SwiftUI

/// The Layouts window (mockup 05, stock layouts only): a sidebar of layouts and, beside it, the selected layout
/// with *Apply to…* and the assignment matrix of workspaces by displays. Colours are the brand's warm neutrals,
/// type follows the app's text size.
struct LayoutsWindowView: View {
    @Bindable var model: LayoutsModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 270)
                .background(LintelBrand.sidebarBackground)
            LintelDivider(axis: .vertical)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LintelBrand.windowBackground)
        }
        .frame(minWidth: 820, minHeight: 540)
        .task { await model.refresh() }
        // A display was plugged, unplugged or changed: the columns follow.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) {
            _ in Task { await model.refresh() }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Layouts", comment: "Layouts window: the title of the sidebar")
                .font(textSize.font(.title2, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stock", comment: "Layouts window: the section of the built-in layouts")
                        .font(textSize.font(.caption1, weight: .semibold))
                        .foregroundStyle(LintelBrand.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(model.stockLayouts, id: \.id) { layout in row(layout) }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private func row(_ layout: GridLayout) -> some View {
        let selected = model.selectedLayoutID == layout.id
        return Button {
            model.selectedLayoutID = layout.id
        } label: {
            HStack(spacing: 10) {
                LayoutThumbnail(layout: layout, size: CGSize(width: 36, height: 24))
                Text(verbatim: model.name(of: layout))
                    .font(textSize.font(.body, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? LintelBrand.accentText : LintelBrand.ink)
                Spacer(minLength: 4)
                Text("Stock", comment: "Layouts window: marks a built-in layout")
                    .font(textSize.font(.caption1))
                    .foregroundStyle(LintelBrand.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(LintelBrand.fill))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? LintelBrand.windowSelectionTint : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: model.name(of: layout)))
        .accessibilityValue(Text(verbatim: model.detail(of: layout)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                layoutCard
                Text("Where each layout is used", comment: "Layouts window: the heading above the assignment matrix")
                    .font(textSize.font(.caption1, weight: .semibold))
                    .foregroundStyle(LintelBrand.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                matrixCard
                notes
            }
            .padding(24)
        }
    }

    private var layoutCard: some View {
        let layout = model.selectedLayout
        return HStack(alignment: .top, spacing: 16) {
            LayoutThumbnail(layout: layout, size: CGSize(width: 130, height: 84))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: model.name(of: layout)).font(textSize.font(.title3, weight: .semibold))
                Text(verbatim: model.detail(of: layout)).font(textSize.font(.callout))
                    .foregroundStyle(LintelBrand.secondaryText)
                Text(verbatim: model.usageText(of: layout)).font(textSize.font(.callout))
                    .foregroundStyle(LintelBrand.secondaryText)
                applyMenu(layout).padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LintelBrand.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LintelBrand.hairline))
    }

    private func applyMenu(_ layout: GridLayout) -> some View {
        Menu {
            Button {
                Task { await model.apply(layout.id, to: .everything) }
            } label: {
                Text("Every workspace on every display", comment: "Layouts window: Apply to… everything")
            }
            if !model.displays.isEmpty {
                Divider()
                ForEach(model.displays) { display in
                    Button {
                        Task { await model.apply(layout.id, to: .display(display.key)) }
                    } label: {
                        Text("All workspaces on \(display.title)", comment: "Layouts window: Apply to… one display")
                    }
                }
            }
            Divider()
            ForEach(model.workspaces, id: \.rawValue) { workspace in
                Button {
                    Task { await model.apply(layout.id, to: .workspace(workspace)) }
                } label: {
                    Text(
                        "Workspace \(workspace.rawValue) on every display",
                        comment: "Layouts window: Apply to… one workspace")
                }
            }
        } label: {
            Text("Apply to…", comment: "Layouts window: opens the menu that writes a layout to many cells")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(!model.canEdit || model.displays.isEmpty)
    }

    // MARK: Matrix

    @ViewBuilder private var matrixCard: some View {
        if model.displays.isEmpty {
            Text("No displays were found.", comment: "Layouts window: the display list is empty")
                .font(textSize.font(.body))
                .foregroundStyle(LintelBrand.secondaryText)
                .padding(16)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Color.clear.frame(width: 120, height: 1)
                    ForEach(model.displays) { display in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: display.title).font(textSize.font(.callout, weight: .semibold))
                            Text(verbatim: display.detail).font(textSize.font(.caption1))
                                .foregroundStyle(LintelBrand.secondaryText)
                            Button {
                                model.identify(display)
                            } label: {
                                Text("Identify", comment: "Layouts window: flashes a number on the display")
                            }
                            .controlSize(.small)
                            .disabled(!model.isActive)
                            .accessibilityLabel(
                                Text(
                                    "Identify \(display.title)",
                                    comment: "Layouts window: identifies one display (spoken)"))
                        }
                    }
                }
                ForEach(Array(model.workspaces.enumerated()), id: \.element.rawValue) { row, workspace in
                    LintelDivider().gridCellColumns(model.displays.count + 1)
                    GridRow {
                        workspaceHeader(workspace)
                        ForEach(Array(model.displays.enumerated()), id: \.element.id) { column, display in
                            cell(
                                model.cell(workspace: workspace, display: display), display: display, row: row,
                                column: column)
                        }
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LintelBrand.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LintelBrand.hairline))
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                guard let key = Self.matrixKey(for: press) else { return .ignored }
                Task { await model.handle(key) }
                return .handled
            }
        }
    }

    /// The keyboard table: arrows move, ⌫ gives the cell back to the default, 1 to 6 pick a stock layout.
    static func matrixKey(for press: KeyPress) -> MatrixKey? {
        switch press.key {
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .upArrow: return .up
        case .downArrow: return .down
        case .delete, .deleteForward: return .clear
        default:
            guard press.modifiers.isEmpty, let digit = Int(press.characters) else { return nil }
            return .layout(digit)
        }
    }

    private func workspaceHeader(_ workspace: WorkspaceID) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Workspace \(workspace.rawValue)", comment: "Window switcher: a workspace")
                .font(textSize.font(.body))
            Menu {
                ForEach(WindowsSettingsModel.selectableKinds, id: \.rawValue) { kind in
                    Button {
                        model.setKind(kind, for: workspace)
                    } label: {
                        if model.kind(of: workspace) == kind {
                            Label(WindowsSettingsModel.kindName(kind), systemImage: "checkmark")
                        } else {
                            Text(verbatim: WindowsSettingsModel.kindName(kind))
                        }
                    }
                }
            } label: {
                Text(verbatim: WindowsSettingsModel.kindName(model.kind(of: workspace)))
                    .font(textSize.font(.caption1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!model.isActive || model.overridesLocked)
            .accessibilityLabel(
                Text(
                    "Layout of workspace \(workspace.rawValue)",
                    comment: "Layouts window: the layout kind of a workspace (spoken)")
            )
            .accessibilityValue(Text(verbatim: WindowsSettingsModel.kindName(model.kind(of: workspace))))
        }
        .frame(width: 120, alignment: .leading)
    }

    private func cell(_ cell: MatrixCell, display: MatrixDisplay, row: Int, column: Int) -> some View {
        let isFocused = model.focused == MatrixPosition(row: row, column: column)
        return Menu {
            Button {
                Task { await model.setLayout(nil, workspace: cell.workspace, displayKey: display.key) }
            } label: {
                if cell.assignedID == nil {
                    Label(model.defaultTitle(for: display), systemImage: "checkmark")
                } else {
                    Text(verbatim: model.defaultTitle(for: display))
                }
            }
            Divider()
            Section {
                ForEach(model.stockLayouts, id: \.id) { layout in
                    Button {
                        Task { await model.setLayout(layout.id, workspace: cell.workspace, displayKey: display.key) }
                    } label: {
                        if cell.assignedID == layout.id {
                            Label(model.name(of: layout), systemImage: "checkmark")
                        } else {
                            Text(verbatim: model.name(of: layout))
                        }
                    }
                }
            } header: {
                Text("Stock", comment: "Layouts window: the section of the built-in layouts")
            }
        } label: {
            HStack {
                Text(verbatim: cell.label).font(textSize.font(.body)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).accessibilityHidden(true)
            }
            .foregroundStyle(cell.isInactive ? LintelBrand.secondaryText : LintelBrand.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 170, maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LintelBrand.fill))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isFocused ? LintelBrand.accent : Color.clear, lineWidth: 2))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(!model.canEdit)
        .help(
            cell.isInactive
                ? Text(
                    "This workspace is not set to Zones, so its zone layout is not used.",
                    comment: "Layouts window: tooltip of a cell on a workspace that is not Zones") : Text(verbatim: "")
        )
        .accessibilityLabel(
            Text(
                "Workspace \(cell.workspace.rawValue), \(display.title)",
                comment: "Layouts window: a matrix cell (spoken)")
        )
        .accessibilityValue(Text(verbatim: cell.label))
    }

    // MARK: Notes

    @ViewBuilder private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.isActive {
                note("Window Management is off. Turn it on to change layouts.")
            }
            if model.writeFailed {
                note("The change could not be saved. Your layouts are unchanged.")
            }
            if model.isLocked {
                note("These assignments were saved by a newer version of Lintel and can’t be changed here.")
            }
            if model.hasDuplicateDisplays {
                note("Two displays look identical to macOS. Lintel tells them apart by their position.")
            }
            if model.fallbackCount > 0 {
                note("Some cells use the default because their layout is missing.")
            }
            note(
                "An empty cell uses the default for the display’s shape. Choose a layout to change it. With a cell selected, use the arrow keys, ⌫ for the default and 1 to 6 for a stock layout."
            )
        }
    }

    private func note(_ key: LocalizedStringResource) -> some View {
        Text(key).font(textSize.font(.caption1)).foregroundStyle(LintelBrand.secondaryText)
    }
}
