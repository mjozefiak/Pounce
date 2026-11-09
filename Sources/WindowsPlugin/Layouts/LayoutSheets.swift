import AppKit
import LintelUI
import SwiftUI

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
