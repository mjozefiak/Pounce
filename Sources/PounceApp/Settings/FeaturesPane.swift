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

/// The "Result order" list (issue #5): the plugins with result sections, in the user's order.
struct SectionOrderControls {
    let host: PluginHost
    let settings: AppSettings

    /// Plugins that contribute search sections, in the current order.
    var ordered: [PluginHost.Entry] {
        SectionOrder.sorted(host.entries.filter { !$0.plugin.searchSources.isEmpty }, saved: settings.sectionOrder)
    }

    /// Moves a section up (−1) or down (+1) and saves the whole order in `app.sectionOrder`.
    func move(_ id: PluginID, by offset: Int) {
        settings.sectionOrder = SectionOrder.moving(id, by: offset, in: ordered.map(\.manifest.id)).map(\.rawValue)
    }

    func restoreDefault() {
        settings.sectionOrder = []
    }
}

/// Settings → Features: every plugin with its switch, its state (an activation error included) and
/// "Erase Data", and the order of the result sections.
struct FeaturesPane: View {
    let controls: FeatureControls
    let order: SectionOrderControls?

    @State private var eraseError: String?

    init(host: PluginHost, settings: AppSettings? = nil, onChange: @escaping () -> Void) {
        controls = FeatureControls(host: host, onChange: onChange)
        order = settings.map { SectionOrderControls(host: host, settings: $0) }
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
            if let order, order.ordered.count > 1 {
                SectionOrderSection(order: order)
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
            // Every row has this button: VoiceOver needs the feature's name to tell them apart.
            .accessibilityLabel(
                Text(
                    "Erase Data of \(String(localized: manifest.displayName))…",
                    comment: "Accessibility label of a feature's Erase Data button"))
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

extension PluginID {
    /// The id of this plugin's row in the Result Order list.
    fileprivate var orderRowID: String { "order:\(rawValue)" }
}

/// "Result order": each search section with Move Up and Move Down buttons (reachable with Tab, unlike
/// drag and drop).
struct SectionOrderSection: View {
    let order: SectionOrderControls

    var body: some View {
        let entries = order.ordered
        Section {
            // Row ids differ from the feature list's (plugin ids): the grouped form is one list, and equal
            // ids in two sections make it draw a feature row in the wrong place.
            ForEach(Array(entries.enumerated()), id: \.element.manifest.id.orderRowID) { index, entry in
                HStack(spacing: 12) {
                    Text("\(index + 1).", comment: "Position in the result order list")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Image(systemName: entry.manifest.symbolName)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text(entry.manifest.displayName)
                    Spacer()
                    Button {
                        order.move(entry.manifest.id, by: -1)
                    } label: {
                        Label {
                            Text("Move Up", comment: "Button that moves a result section up")
                        } icon: {
                            Image(systemName: "chevron.up")
                        }
                        .labelStyle(.iconOnly)
                    }
                    .disabled(index == 0)
                    .help(Text("Move Up", comment: "Button that moves a result section up"))
                    Button {
                        order.move(entry.manifest.id, by: 1)
                    } label: {
                        Label {
                            Text("Move Down", comment: "Button that moves a result section down")
                        } icon: {
                            Image(systemName: "chevron.down")
                        }
                        .labelStyle(.iconOnly)
                    }
                    .disabled(index == entries.count - 1)
                    .help(Text("Move Down", comment: "Button that moves a result section down"))
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(
                    Text(
                        "\(String(localized: entry.manifest.displayName)), position \(index + 1) of \(entries.count)",
                        comment: "Accessibility label of a result section in the order list"))
            }
        } header: {
            Text("Result Order", comment: "Settings section title")
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    "Sections appear in the panel in this order.",
                    comment: "Settings footer of the result order"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    order.restoreDefault()
                } label: {
                    Text("Restore Default Order", comment: "Button that restores the default result order")
                }
                .disabled(order.settings.sectionOrder.isEmpty)
            }
        }
    }
}
