import LintelUI
import SwiftUI

/// Settings → General → "Updates" (spec `2026-11-19-updates-and-open-source-hygiene`, Step 4.5). When the updater is
/// off in this copy (DEBUG, outside Applications, ad-hoc signature) it shows the version and one line, no switches.
struct UpdatesSection: View {
    let model: UpdatesSettingsModel

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        Section {
            LabeledContent {
                Text(versionText)
                    .font(textSize.font(.body))
                    .foregroundStyle(LintelBrand.secondaryText)
                    .textSelection(.enabled)
            } label: {
                Text("Version", comment: "Settings → General → Updates: label of the current version")
                    .font(textSize.font(.body))
            }
            .accessibilityElement(children: .combine)
            if model.isAvailable {
                Toggle(isOn: binding(model.automaticChecks, model.setAutomaticChecks)) {
                    Text("Check for updates automatically", comment: "Settings → General → Updates: switch")
                        .font(textSize.font(.body))
                }
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Check for updates automatically", comment: "VoiceOver label of the switch"))
                Toggle(isOn: binding(model.automaticDownloads, model.setAutomaticDownloads)) {
                    Text("Download and install updates automatically", comment: "Settings → General → Updates: switch")
                        .font(textSize.font(.body))
                }
                .toggleStyle(.switch)
                .disabled(!model.automaticChecks)
                .accessibilityLabel(
                    Text("Download and install updates automatically", comment: "VoiceOver label of the switch"))
                Toggle(isOn: binding(model.includeBeta, model.setIncludeBeta)) {
                    Text("Include beta versions", comment: "Settings → General → Updates: switch")
                        .font(textSize.font(.body))
                    if model.runsPreRelease {
                        Text("You are running a beta version.", comment: "Settings → General → Updates: note")
                            .font(textSize.font(.callout))
                            .foregroundStyle(LintelBrand.secondaryText)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Include beta versions", comment: "VoiceOver label of the switch"))
                LabeledContent {
                    Button {
                        model.checkNow()
                    } label: {
                        Text("Check Now", comment: "Settings → General → Updates: button that checks for an update")
                    }
                    .disabled(!model.canCheckNow)
                    .accessibilityLabel(
                        Text("Check for updates now", comment: "VoiceOver label of the Check Now button"))
                } label: {
                    EmptyView()
                }
            } else {
                Text(
                    "Updates are not available in this copy of Lintel.",
                    comment: "Settings → General → Updates: shown when the updater is off"
                )
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.secondaryText)
            }
        } header: {
            Text("Updates", comment: "Settings → General: section title of the update settings")
                .settingsSectionHeader()
        }
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var versionText: String {
        model.build.isEmpty || model.build == model.version
            ? model.version
            : String(
                localized: "\(model.version) (build \(model.build))",
                comment: "Settings → General → Updates: version and build number")
    }

    private func binding(_ value: Bool, _ set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: set)
    }
}
