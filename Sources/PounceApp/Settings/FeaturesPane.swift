import PounceKit
import SwiftUI

/// What the Features pane's controls do, kept out of the view so the binding to `PluginHost` is tested
/// (spec step 1.2b).
struct FeatureControls {
    let host: PluginHost
    /// Called after a plugin was turned on or off or erased, so shortcuts and menus follow.
    let onChange: () -> Void

    func isEnabled(_ id: PluginID) -> Bool {
        host.isEnabled(id)
    }

    /// The switch: persists `plugins.<id>.enabled` and activates or deactivates the plugin.
    func setEnabled(_ enabled: Bool, for id: PluginID) async {
        await host.setEnabled(enabled, for: id)
        onChange()
    }

    /// "Erase Data". Returns the error message to show, or `nil` when it worked.
    func erase(_ id: PluginID) async -> String? {
        defer { onChange() }
        do {
            try await host.eraseData(for: id)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Settings → Features: every plugin with its switch, its state (an activation error included) and
/// "Erase Data".
struct FeaturesPane: View {
    let controls: FeatureControls

    @State private var eraseError: String?

    init(host: PluginHost, onChange: @escaping () -> Void) {
        controls = FeatureControls(host: host, onChange: onChange)
    }

    var body: some View {
        Form {
            Section {
                ForEach(controls.host.entries, id: \.manifest.id) { entry in
                    FeatureRow(
                        manifest: entry.manifest,
                        state: entry.state,
                        isEnabled: controls.isEnabled(entry.manifest.id),
                        setEnabled: { enabled in
                            Task { await controls.setEnabled(enabled, for: entry.manifest.id) }
                        },
                        erase: {
                            Task { eraseError = await controls.erase(entry.manifest.id) }
                        }
                    )
                }
            } header: {
                Text("Features", comment: "Settings section title")
            } footer: {
                Text(
                    "Turning a feature off stops it and hides its results. Its data stays until you erase it.",
                    comment: "Settings footer for the feature list"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .alert(
            Text("The data could not be erased.", comment: "Alert title when Erase Data fails"),
            isPresented: Binding(get: { eraseError != nil }, set: { if !$0 { eraseError = nil } })
        ) {
            Button {
                eraseError = nil
            } label: {
                Text("OK", comment: "Button that dismisses an alert")
            }
        } message: {
            Text(eraseError ?? "")
        }
    }
}

struct FeatureRow: View {
    let manifest: PluginManifest
    let state: PluginState
    let isEnabled: Bool
    let setEnabled: (Bool) -> Void
    let erase: () -> Void

    @State private var confirmsErase = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: manifest.symbolName)
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(manifest.displayName)
                status
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                confirmsErase = true
            } label: {
                Text("Erase Data…", comment: "Settings button that deletes a feature's data")
            }
            Toggle(isOn: Binding(get: { isEnabled }, set: { setEnabled($0) })) {
                Text(manifest.displayName)
            }
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .confirmationDialog(
            Text(
                "Erase all data of “\(String(localized: manifest.displayName))”?", comment: "Erase confirmation title"),
            isPresented: $confirmsErase
        ) {
            Button(role: .destructive) {
                erase()
            } label: {
                Text("Erase Data", comment: "Confirmation button that deletes a feature's data")
            }
        } message: {
            Text(
                "This deletes everything the feature stored on this Mac. It cannot be undone.",
                comment: "Erase confirmation message"
            )
        }
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .active:
            Text("On", comment: "Feature state")
        case .disabled:
            Text("Off", comment: "Feature state")
        case .activating:
            Text("Starting…", comment: "Feature state")
        case .failed(let error):
            Label {
                Text("Unavailable: \(error.localizedDescription)", comment: "Feature state with the error message")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }
}
