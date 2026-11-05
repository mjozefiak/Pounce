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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: row.model.title)
                        .font(textSize.font(.body))
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: size)
                        .font(textSize.font(.callout))
                        .foregroundStyle(.secondary)
                }
                stateLine
                if let progress = row.progress {
                    ProgressView(value: progress.fraction)
                        .accessibilityLabel(Text("Download progress", comment: "Models pane: progress bar label"))
                }
                if !row.usedBy.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(row.usedBy) { chip($0) }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: row.usedByText ?? ""))
                }
                if let error = row.errorMessage {
                    Text(verbatim: error)
                        .font(textSize.font(.callout))
                        .foregroundStyle(LintelBrand.statusError)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            buttons
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var stateLine: some View {
        HStack(spacing: 6) {
            Text(verbatim: row.stateText)
            if row.isNeeded {
                Text("Needed", comment: "Models pane: a feature that is on requires this model")
                    .foregroundStyle(LintelBrand.statusAttention)
            }
        }
        .font(textSize.font(.callout, weight: .medium))
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
            .background(.quaternary, in: Capsule())
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

    private func label(_ text: Text) -> some View {
        text.font(textSize.font(.body))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if row.isDownloading {
                Button(action: cancel) { label(Text("Cancel", comment: "Models pane: stops a download")) }
            } else if row.isInstalled {
                Button(action: remove) {
                    label(Text("Remove", comment: "Models pane: deletes a downloaded model"))
                }
                .disabled(row.isBusy)
            } else if row.model.canDownload {
                Button(action: download) {
                    if row.errorMessage != nil {
                        label(
                            Text(
                                LocalizedStringResource(
                                    "Try Again (download)", defaultValue: "Try Again",
                                    comment: "Models pane: downloads a model again after an error")))
                    } else {
                        label(Text("Download", comment: "Models pane: downloads a model"))
                    }
                }
                .disabled(row.isBusy)
            }
            let folderUsers = row.usedBy.filter(\.canChooseFolder)
            if folderUsers.count == 1, let only = folderUsers.first {
                Button {
                    chooseFolder(only.pluginID)
                } label: {
                    label(Text("Choose Folder…", comment: "Models pane: use a model folder downloaded by hand"))
                }
                .disabled(row.isBusy || row.isDownloading)
            } else if folderUsers.count > 1 {
                Menu {
                    ForEach(folderUsers) { user in
                        Button {
                            chooseFolder(user.pluginID)
                        } label: {
                            Text(
                                "For \(user.pluginName)", comment: "Models pane: choose a model folder for one feature")
                        }
                    }
                } label: {
                    label(Text("Choose Folder…", comment: "Models pane: use a model folder downloaded by hand"))
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(row.isBusy || row.isDownloading)
            }
        }
        .buttonStyle(.bordered)
    }
}
