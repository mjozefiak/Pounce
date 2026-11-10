import AppKit
import LintelUI
import SwiftUI

/// The Layouts window (mockup 05, stock layouts only): a sidebar of layouts and, beside it, the selected layout
/// with *Apply to…* and the assignment matrix of workspaces by displays. Colours are the brand's warm neutrals,
/// type follows the app's text size.
struct LayoutsWindowView: View {
    @Bindable var model: LayoutsModel
    @Environment(\.lintelTextSize) var textSize

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 320)
                .background(LintelBrand.sidebarBackground)
            LintelDivider(axis: .vertical)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LintelBrand.windowBackground)
        }
        .frame(minWidth: 900, minHeight: 560)
        .task { await model.refresh() }
        .destructiveConfirmation(
            isPresented: Binding(
                get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }),
            model.pendingDelete?.confirmation ?? Self.noDeletion
        ) {
            model.actions.enqueue { await model.confirmDelete() }
        }
        .sheet(isPresented: $model.isRenaming) {
            RenameLayoutSheet(
                name: model.selectedLayout.name,
                onRename: { name in model.actions.enqueue { await model.renameSelected(to: name) } },
                onCancel: { model.isRenaming = false })
        }
        .sheet(
            isPresented: Binding(
                get: { model.pendingImport != nil }, set: { if !$0 { model.cancelImport() } })
        ) {
            if let preview = model.pendingImport {
                ImportSummarySheet(
                    lines: model.importLines(preview), canImport: !preview.isEmpty,
                    onImport: { model.actions.enqueue { await model.confirmImport() } },
                    onCancel: { model.cancelImport() })
            }
        }
        // A display was plugged, unplugged or changed: the columns follow.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) {
            _ in model.actions.enqueue { await model.refresh() }
        }
    }

    private static let noDeletion = DestructiveConfirmation(
        prompt: LocalizedStringResource("Delete this layout?", comment: "Layouts window: asked before a delete"),
        detail: LocalizedStringResource(
            "This can’t be undone.", comment: "Confirmation sheet: the consequence line of a destructive action"),
        confirmTitle: LocalizedStringResource("Delete", comment: "Layouts window: deletes the selected layout"))

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
                model.actions.enqueue { await model.apply(layout.id, to: .everything) }
            } label: {
                Text("Every workspace on every display", comment: "Layouts window: Apply to… everything")
            }
            if !model.displays.isEmpty {
                Divider()
                ForEach(model.displays) { display in
                    Button {
                        model.actions.enqueue { await model.apply(layout.id, to: .display(display.key)) }
                    } label: {
                        Text("All workspaces on \(display.title)", comment: "Layouts window: Apply to… one display")
                    }
                }
            }
            Divider()
            ForEach(model.workspaces, id: \.rawValue) { workspace in
                Button {
                    model.actions.enqueue { await model.apply(layout.id, to: .workspace(workspace)) }
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
                    model.actions.enqueue { await model.setSlot(number, to: bound ? nil : layout.id) }
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

    // MARK: Notes

    @ViewBuilder var notes: some View {
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
