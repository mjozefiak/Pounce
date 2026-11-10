import AppKit
import LintelUI
import SwiftUI

/// The assignment matrix of the Layouts window: workspaces by displays.
extension LayoutsWindowView {
    // MARK: Matrix

    @ViewBuilder var matrixCard: some View {
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
                model.actions.enqueue { await model.handle(key) }
                return .handled
            }
        }
    }

    /// The keyboard table: arrows move, ⌫ gives the cell back to the default, 1 to 6 pick a stock layout.
    static func matrixKey(for press: KeyPress) -> MatrixKey? {
        matrixKey(key: press.key, characters: press.characters, modifiers: press.modifiers)
    }

    /// The table on plain values (a `KeyPress` cannot be built in a test).
    static func matrixKey(key: KeyEquivalent, characters: String, modifiers: EventModifiers) -> MatrixKey? {
        // The one policy of `DeleteKeys` (Shift allowed; Cmd, Ctrl, Option not; Caps Lock and Function ignored).
        if DeleteKeys.isPlainDelete(key: key, characters: characters, modifiers: modifiers) { return .clear }
        switch key {
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .upArrow: return .up
        case .downArrow: return .down
        default:
            guard DeleteKeys.meaningful(modifiers).isEmpty, let digit = Int(characters) else { return nil }
            return .layout(digit)
        }
    }

    func workspaceHeader(_ workspace: WorkspaceID) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Workspace \(workspace.rawValue)", comment: "Window switcher: a workspace")
                .font(textSize.font(.body))
            Menu {
                ForEach(model.selectableKinds, id: \.rawValue) { kind in
                    Button {
                        model.setKind(kind, for: workspace)
                    } label: {
                        if model.kind(of: workspace) == kind {
                            Label(model.kindName(kind), systemImage: "checkmark")
                        } else {
                            Text(verbatim: model.kindName(kind))
                        }
                    }
                }
            } label: {
                Text(verbatim: model.kindName(model.kind(of: workspace)))
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
            .accessibilityValue(Text(verbatim: model.kindName(model.kind(of: workspace))))
        }
        .frame(width: 120, alignment: .leading)
    }

    func cell(_ cell: MatrixCell, display: MatrixDisplay, row: Int, column: Int) -> some View {
        let isFocused = model.focused == MatrixPosition(row: row, column: column)
        return Menu {
            Button {
                model.actions.enqueue { await model.setLayout(nil, workspace: cell.workspace, displayKey: display.key) }
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
                        model.actions.enqueue {
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
                Text("Stock", comment: "Layouts window: the section of the built-in layouts")
            }
            if !model.userLayouts.isEmpty {
                Divider()
                Section {
                    ForEach(model.userLayouts, id: \.id) { layout in
                        Button {
                            model.actions.enqueue {
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
                    "This workspace uses a layout kind that does not use these layouts.",
                    comment:
                        "Layouts window: tooltip of a cell on a workspace whose layout kind does not use the layout library"
                ) : Text(verbatim: "")
        )
        .accessibilityLabel(
            Text(
                "Workspace \(cell.workspace.rawValue), \(display.title)",
                comment: "Layouts window: a matrix cell (spoken)")
        )
        .accessibilityValue(Text(verbatim: cell.label))
    }
}
