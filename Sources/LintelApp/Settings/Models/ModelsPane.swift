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

    var body: some View {
        ScrollViewReader { proxy in
            SettingsPane {
                ForEach(model.kinds, id: \.self) { kind in
                    Section {
                        ForEach(model.rows(of: kind)) { row in
                            ModelRow(
                                row: row,
                                download: { model.download(row.id) },
                                cancel: { model.cancelDownload(row.id) },
                                remove: { Task { await model.remove(row.id) } },
                                chooseFolder: { pluginID in Task { await model.chooseFolder(row.id, for: pluginID) } }
                            )
                            .id(row.id)
                        }
                    } header: {
                        Text(Self.title(of: kind))
                            .font(textSize.font(.body, weight: .semibold))
                    }
                }
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

    static func title(of kind: ModelKind) -> String {
        switch kind {
        case .speech: String(localized: "Speech Recognition", comment: "Models pane section: speech models")
        case .llm: String(localized: "Language Models", comment: "Models pane section: built-in language models")
        case .diarization: String(localized: "Speaker Recognition", comment: "Models pane section: diarization")
        default: kind.rawValue
        }
    }
}
