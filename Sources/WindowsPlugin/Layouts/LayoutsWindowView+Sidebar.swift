import AppKit
import LintelUI
import SwiftUI

/// The sidebar of the Layouts window: the library's buttons and one row per layout.
extension LayoutsWindowView {
    // MARK: Sidebar

    var sidebar: some View {
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

    func sectionHeader(_ title: Text) -> some View {
        title
            .font(textSize.font(.caption1, weight: .semibold))
            .foregroundStyle(LintelBrand.secondaryText)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    var libraryButtons: some View {
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

    func row(_ layout: GridLayout) -> some View {
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
}
