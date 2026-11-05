import AppKit
import LintelKit
import LintelUI
import SwiftUI

/// Settings → Models (spec `2026-11-04-lintel-main-window`, step 3.2, D6): one section per kind of model, a
/// `ModelRow` per catalog package. Main window only; the old Settings window keeps the plugins' model cards. The
/// "1 model is needed" banner is drawn by `SettingsHost` from `ModelsPaneModel.banner`.
struct ModelsPane: View {
    let model: ModelsPaneModel
    /// The row an `openModels(packageID)` asked for; taken once when the pane appears.
    var takeScrollTarget: () -> String? = { nil }

    @Environment(\.lintelTextSize) private var textSize
    @State private var storageExpanded = false

    private func footerText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(textSize.font(.callout))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        ScrollViewReader { proxy in
            SettingsPane {
                ForEach(model.sections) { section in
                    Section {
                        ForEach(model.rows(in: section)) { row in
                            ModelRow(
                                row: row,
                                download: { model.download(row.id) },
                                cancel: { model.cancelDownload(row.id) },
                                remove: { model.requestRemoval(row.id) },
                                chooseFolder: { pluginID in Task { await model.chooseFolder(row.id, for: pluginID) } }
                            )
                            .id(row.id)
                        }
                    } header: {
                        Text(verbatim: section.title)
                            .settingsSectionHeader()
                    } footer: {
                        if section.id == "writing", let footer = model.writingMemoryFooter {
                            footerText(footer)
                        }
                    }
                }
                SettingsDisclosureSection(isExpanded: $storageExpanded) {
                    LabeledContent {
                        Button {
                            model.showInFinder()
                        } label: {
                            Label {
                                Text("Show in Finder", comment: "Models pane: reveals the models folder")
                            } icon: {
                                Image(systemName: "folder")
                            }
                            .font(textSize.font(.body))
                        }
                        .buttonStyle(LintelSecondaryButtonStyle())
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("On this Mac", comment: "Models pane storage: where the models live")
                                .font(textSize.font(.body))
                            Text(verbatim: model.storageDetail)
                                .font(textSize.font(.callout))
                                .foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Text("Storage", comment: "Models pane: disclosure group for where models are kept")
                } footer: {
                    footerText(
                        String(
                            localized: "Models run on this Mac. Audio never leaves it.",
                            comment: "Models pane footer: models run locally"))
                }
            }
            .destructiveConfirmation(
                isPresented: Binding(
                    get: { model.pendingRemoval != nil }, set: { if !$0 { model.cancelRemoval() } }),
                model.removalConfirmation
            ) {
                model.confirmRemoval()
            }
            .task {
                if let target = takeScrollTarget() { model.scrollTarget = target }
                await model.refresh()
                if let target = model.scrollTarget {
                    proxy.scrollTo(target, anchor: .top)
                    model.scrollTarget = nil
                }
            }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .top)
                model.scrollTarget = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.refresh() }
            }
        }
    }
}
