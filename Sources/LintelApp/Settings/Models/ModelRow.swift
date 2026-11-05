import LintelKit
import LintelUI
import SwiftUI

/// One model in Settings → Models: name, size, state in words, "used by" chips, and Download / Cancel / Remove /
/// Try Again and "Choose Folder…" per feature that offers one (D6: the Models pane owns download, removal and
/// storage).
struct ModelRow: View {
    let row: ModelsPaneModel.Row
    var download: () -> Void = {}
    var cancel: () -> Void = {}
    var remove: () -> Void = {}
    var chooseFolder: (_ pluginID: String) -> Void = { _ in }

    @Environment(\.lintelTextSize) private var textSize

    private var size: String {
        ByteCountFormatter.string(fromByteCount: Int64(row.model.bytes), countStyle: .file)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: row.title)
                    .font(textSize.font(.body, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let license = row.model.license {
                    Text(verbatim: license)
                        .font(textSize.font(.callout))
                        .foregroundStyle(LintelBrand.secondaryText)
                }
            }
            HStack(spacing: 6) {
                ForEach(row.usedBy) { chip($0) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: row.usedByText ?? ""))
                if !row.usedBy.isEmpty {
                    Text(verbatim: "·").foregroundStyle(LintelBrand.secondaryText)
                }
                Text(verbatim: size)
                    .foregroundStyle(LintelBrand.secondaryText)
            }
            .font(textSize.font(.callout))
            if let progress = row.progress {
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 200)
                    .accessibilityLabel(Text("Download progress", comment: "Models pane: progress bar label"))
            }
            if let error = row.errorMessage {
                Text(verbatim: error)
                    .font(textSize.font(.callout))
                    .foregroundStyle(LintelBrand.statusError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var state: some View {
        Text(verbatim: row.stateText)
            .font(textSize.font(.callout))
            .foregroundStyle(
                row.isInstalled ? AnyShapeStyle(LintelBrand.statusOk) : AnyShapeStyle(LintelBrand.secondaryText)
            )
            .lineLimit(1)
            .fixedSize()
    }

    /// One line while it fits; at large text sizes the state and the buttons drop under the name so a button
    /// label never wraps.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                info
                Spacer(minLength: 12)
                state
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                info
                HStack(spacing: 12) {
                    state
                    Spacer(minLength: 12)
                    buttons
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func chip(_ usedBy: ModelsPaneModel.UsedBy) -> some View {
        ModelRowChip(usedBy: usedBy)
    }

    private var buttons: some View {
        ModelRowButtons(
            row: row, download: download, cancel: cancel, remove: remove, chooseFolder: chooseFolder)
    }
}

/// A "used by" chip.
struct ModelRowChip: View {
    let usedBy: ModelsPaneModel.UsedBy
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        Text(verbatim: usedBy.label)
            .font(textSize.font(.caption1))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(LintelBrand.fill, in: Capsule())
            .opacity(usedBy.isEnabled ? 1 : 0.6)
            .help(Text(verbatim: usedBy.role))
    }
}

/// The row's buttons. Every one is a bordered button whose label uses the `lintelTextSize` font (the prototype's
/// `set-models` draws "Choose Folder…" as a bordered button next to Download / Remove).
struct ModelRowButtons: View {
    let row: ModelsPaneModel.Row
    var download: () -> Void = {}
    var cancel: () -> Void = {}
    var remove: () -> Void = {}
    var chooseFolder: (_ pluginID: String) -> Void = { _ in }

    @Environment(\.lintelTextSize) private var textSize

    /// The prototype's download glyph on the Download buttons (`set-models`).
    static let downloadSymbol = "arrow.down.to.line"

    private func label(_ text: Text, systemImage: String? = nil) -> some View {
        Group {
            if let systemImage {
                Label {
                    text
                } icon: {
                    Image(systemName: systemImage)
                }
            } else {
                text
            }
        }
        .font(textSize.font(.body)).lineLimit(1).fixedSize()
    }

    /// The one "Choose Folder…" label, in the one secondary button style, whether one feature or several offer it.
    private var folderLabel: some View {
        label(
            Text(
                LocalizedStringResource(
                    "Choose Folder… (models)", defaultValue: "Choose Folder…",
                    comment: "Models pane: use a model folder downloaded by hand")))
    }

    var body: some View {
        HStack(spacing: 8) {
            folderButton
            actionButton
        }
        .buttonStyle(LintelSecondaryButtonStyle())
    }

    @ViewBuilder private var actionButton: some View {
        if row.isDownloading {
            Button(action: cancel) { label(Text("Cancel", comment: "Models pane: stops a download")) }
        } else if row.isInstalled {
            Button(action: remove) {
                label(Text("Remove", comment: "Models pane: deletes a downloaded model"))
            }
            .buttonStyle(LintelDestructiveButtonStyle())
            .disabled(row.isBusy)
        } else if row.model.canDownload {
            if row.isPrimaryAction {
                Button(action: download) { downloadLabel }
                    .buttonStyle(LintelPrimaryButtonStyle())
                    .disabled(row.isBusy)
            } else {
                Button(action: download) { downloadLabel }
                    .disabled(row.isBusy)
            }
        }
    }

    @ViewBuilder private var downloadLabel: some View {
        if row.errorMessage != nil {
            label(
                Text(
                    LocalizedStringResource(
                        "Try Again (download)", defaultValue: "Try Again",
                        comment: "Models pane: downloads a model again after an error")))
        } else {
            label(
                Text("Download", comment: "Models pane: downloads a model"),
                systemImage: ModelRowButtons.downloadSymbol)
        }
    }

    @ViewBuilder private var folderButton: some View {
        let folderUsers = row.usedBy.filter(\.canChooseFolder)
        if folderUsers.count == 1, let only = folderUsers.first {
            Button {
                chooseFolder(only.pluginID)
            } label: {
                folderLabel
            }
            .disabled(row.isBusy || row.isDownloading)
        } else if folderUsers.count > 1 {
            Menu {
                ForEach(folderUsers) { user in
                    Button {
                        chooseFolder(user.pluginID)
                    } label: {
                        Text("For \(user.pluginName)", comment: "Models pane: choose a model folder for one feature")
                    }
                }
            } label: {
                folderLabel
            }
            .menuStyle(.button)
            .buttonStyle(LintelSecondaryButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(row.isBusy || row.isDownloading)
        }
    }
}
