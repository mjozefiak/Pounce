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
        .destructiveConfirmation(
            isPresented: Binding(
                get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }),
            model.pendingDelete?.confirmation ?? Self.noDeletion
        ) {
            Task { await model.confirmDelete() }
        }
        .sheet(isPresented: $model.isRenaming) {
            RenameLayoutSheet(
                name: model.selectedLayout.name,
                onRename: { name in Task { await model.renameSelected(to: name) } },
                onCancel: { model.isRenaming = false })
        }
        .sheet(
            isPresented: Binding(
                get: { model.pendingImport != nil }, set: { if !$0 { model.cancelImport() } })
        ) {
            if let preview = model.pendingImport {
                ImportSummarySheet(
                    lines: model.importLines(preview), canImport: !preview.isEmpty,
                    onImport: { Task { await model.confirmImport() } }, onCancel: { model.cancelImport() })
            }
        }
        // A display was plugged, unplugged or changed: the columns follow.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) {
            _ in Task { await model.refresh() }
        }
    }

    private static let noDeletion = DestructiveConfirmation(
        prompt: LocalizedStringResource("Delete this layout?", comment: "Layouts window: asked before a delete"),
        detail: LocalizedStringResource(
            "This can’t be undone.", comment: "Confirmation sheet: the consequence line of a destructive action"),
        confirmTitle: LocalizedStringResource("Delete", comment: "Layouts window: deletes the selected layout"))

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
                    sectionHeader(Text("Stock", comment: "Layouts window: the section of the built-in layouts"))
                    ForEach(model.stockLayouts, id: \.id) { layout in row(layout) }
                    sectionHeader(Text("Mine", comment: "Layouts window: the section of the user's own layouts"))
                        .padding(.top, 10)
                    if model.userLayouts.isEmpty {
                        Text(
                            "Layouts you make or import appear here.",
                            comment: "Layouts window: the user's own section is empty"
                        )
                        .font(textSize.font(.callout))
                        .foregroundStyle(LintelBrand.secondaryText)
                        .padding(.horizontal, 8)
                    }
                    ForEach(model.userLayouts, id: \.id) { layout in row(layout) }
                }
                .padding(.horizontal, 12)
            }
            LintelDivider()
            libraryButtons
                .padding(12)
        }
    }

    private func sectionHeader(_ title: Text) -> some View {
        title
            .font(textSize.font(.caption1, weight: .semibold))
            .foregroundStyle(LintelBrand.secondaryText)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private var libraryButtons: some View {
        HStack(spacing: 8) {
            Button {
                model.newLayout()
            } label: {
                Text("New layout", comment: "Layouts window: makes a new layout in the editor")
            }
            .buttonStyle(LintelPrimaryButtonStyle())
            .disabled(!model.canEditLibrary)
            Button {
                Task { await model.duplicateSelected() }
            } label: {
                Text("Duplicate", comment: "Layouts window: makes an editable copy of the selected layout")
            }
            .disabled(!model.canEditLibrary)
            Button {
                model.beginImport()
            } label: {
                Text("Import", comment: "Layouts window: adds layouts from a file")
            }
            .disabled(!model.canEditLibrary)
            Menu {
                Button {
                    model.export(.selected)
                } label: {
                    Text("Export Selected Layout…", comment: "Layouts window: writes the selected layout to a file")
                }
                Button {
                    model.export(.allMine)
                } label: {
                    Text("Export All My Layouts…", comment: "Layouts window: writes the user's layouts to a file")
                }
                .disabled(model.userLayouts.isEmpty)
            } label: {
                Text("Export", comment: "Layouts window: writes layouts to a file")
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(!model.isActive)
        }
        .controlSize(.small)
        .lineLimit(1)
    }

    private func row(_ layout: GridLayout) -> some View {
        let selected = model.selectedLayoutID == layout.id
        let stock = model.isStock(layout)
        return Button {
            model.selectedLayoutID = layout.id
        } label: {
            HStack(spacing: 10) {
                LayoutThumbnail(layout: layout, size: CGSize(width: 36, height: 24))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: model.name(of: layout))
                        .font(textSize.font(.body, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? LintelBrand.accentText : LintelBrand.ink)
                        .lineLimit(1)
                    if !stock {
                        Text(verbatim: model.rowDetail(of: layout))
                            .font(textSize.font(.caption1))
                            .foregroundStyle(LintelBrand.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if stock {
                    Text("Stock", comment: "Layouts window: marks a built-in layout")
                        .font(textSize.font(.caption1))
                        .foregroundStyle(LintelBrand.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(LintelBrand.fill))
                }
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
        .accessibilityValue(Text(verbatim: model.rowDetail(of: layout)))
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
                HStack(spacing: 8) {
                    if !model.isStock(layout) {
                        Button {
                            model.editSelected()
                        } label: {
                            Text("Edit…", comment: "Layouts window: opens the layout in the editor")
                        }
                        .disabled(!model.canEditSelected)
                        Button {
                            model.isRenaming = true
                        } label: {
                            Text("Rename…", comment: "Layouts window: changes the name of the selected layout")
                        }
                        .disabled(!model.canEditSelected)
                    }
                    applyMenu(layout)
                    slotMenu(layout)
                    if !model.isStock(layout) {
                        Button(role: .destructive) {
                            model.requestDelete()
                        } label: {
                            Text("Delete…", comment: "Layouts window: deletes the selected layout")
                        }
                        .disabled(!model.canEditSelected)
                    }
                }
                .padding(.top, 6)
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

    private func slotMenu(_ layout: GridLayout) -> some View {
        Menu {
            ForEach(1...LayoutRules.slotCount, id: \.self) { number in
                let bound = model.slots[number] == layout.id
                Button {
                    Task { await model.setSlot(number, to: bound ? nil : layout.id) }
                } label: {
                    if bound {
                        Label(
                            "Layout slot \(number)", systemImage: "checkmark")
                    } else {
                        Text("Layout slot \(number)", comment: "Layouts window: a numbered shortcut slot")
                    }
                }
            }
        } label: {
            Text("Slot", comment: "Layouts window: binds the layout to a numbered shortcut slot")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(!model.canEditLibrary)
        .accessibilityLabel(
            Text("Shortcut slot", comment: "Layouts window: the slot menu of a layout (spoken)")
        )
        .help(
            Text(
                "A slot is a command with its own shortcut. Set the shortcut in Settings → Window Management.",
                comment: "Layouts window: tooltip of the slot menu"))
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
            if !model.userLayouts.isEmpty {
                Divider()
                Section {
                    ForEach(model.userLayouts, id: \.id) { layout in
                        Button {
                            Task {
                                await model.setLayout(layout.id, workspace: cell.workspace, displayKey: display.key)
                            }
                        } label: {
                            if cell.assignedID == layout.id {
                                Label(model.name(of: layout), systemImage: "checkmark")
                            } else {
                                Text(verbatim: model.name(of: layout))
                            }
                        }
                    }
                } header: {
                    Text("Mine", comment: "Layouts window: the section of the user's own layouts")
                }
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
            if let notice = model.notice {
                Text(verbatim: notice).font(textSize.font(.caption1)).foregroundStyle(LintelBrand.secondaryText)
            }
            if model.libraryLocked {
                note("These layouts were saved by a newer version of Lintel and can’t be changed here.")
            }
            if model.keptUntouched > 0 {
                note("Some layouts in your library use a style this version doesn’t know. They are kept as they are.")
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

/// *Rename…*: a sheet with the name field. The name is user data: 1 to 64 characters, no control characters.
struct RenameLayoutSheet: View {
    @State var name: String
    var onRename: (String) -> Void
    var onCancel: () -> Void
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename layout", comment: "Layouts window: the title of the rename sheet")
                .font(textSize.font(.headline))
            TextField(text: $name) {
                Text("Name", comment: "Layout editor: the field that names the layout")
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { if LayoutRules.isValidName(name) { onRename(name) } }
            if !LayoutRules.isValidName(name) {
                Text(
                    "Use 1 to 64 characters, without control characters.",
                    comment: "Layout editor: the name is empty, too long or has forbidden characters"
                )
                .font(textSize.font(.caption1))
                .foregroundStyle(LintelBrand.statusError)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(action: onCancel) {
                    Text("Cancel", comment: "Confirmation sheet button that keeps everything as it is")
                }
                .buttonStyle(LintelSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                Button {
                    onRename(name)
                } label: {
                    Text("Rename", comment: "Layouts window: confirms the new name")
                }
                .buttonStyle(LintelPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!LayoutRules.isValidName(name))
            }
        }
        .padding(20)
        .frame(width: 380)
        .presentationBackground(LintelBrand.windowBackground)
    }
}

/// What an import would do, before anything is added (spec: Data Model).
struct ImportSummarySheet: View {
    var lines: [String]
    var canImport: Bool
    var onImport: () -> Void
    var onCancel: () -> Void
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import layouts?", comment: "Layouts window: the title of the import summary")
                .font(textSize.font(.headline))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(textSize.font(.callout)).foregroundStyle(LintelBrand.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button(action: onCancel) {
                    Text("Cancel", comment: "Confirmation sheet button that keeps everything as it is")
                }
                .buttonStyle(LintelSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                Button(action: onImport) {
                    Text("Import", comment: "Layouts window: adds layouts from a file")
                }
                .buttonStyle(LintelPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canImport)
            }
        }
        .padding(20)
        .frame(width: 400)
        .presentationBackground(LintelBrand.windowBackground)
    }
}
