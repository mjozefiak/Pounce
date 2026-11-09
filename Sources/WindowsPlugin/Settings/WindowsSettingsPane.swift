import LintelKit
import LintelUI
import SwiftUI

/// Settings → Window Management on the `SettingsPane` template (prototype `set-windows`): Basics, a collapsed
/// Advanced and Data. The banner is the host's, from `WindowsPlugin.settingsStatus`. Basics has the default layout
/// kind (Auto-tile, Zones or Free), the gaps, the *Layouts…* row that opens the Layouts window and the default
/// zone layout of each display shape.
struct WindowsSettingsPane: View {
    @Bindable var model: WindowsSettingsModel
    /// `false` while the plugin is off or failed: the pane then reads nothing and starts nothing.
    var isActive = true

    @Environment(\.lintelTextSize) var textSize
    @State var confirmsReset = false

    static let resetConfirmation = DestructiveConfirmation(
        prompt: LocalizedStringResource("Reset window state?", comment: "Window Management confirmation title"),
        detail: LocalizedStringResource(
            "Every window is put back first, then the workspaces are forgotten. This can’t be undone.",
            comment: "Window Management confirmation text"),
        confirmTitle: LocalizedStringResource("Reset State", comment: "Window Management confirmation button"))

    var body: some View {
        SettingsPane(
            basics: {
                Section {
                    if let failure = model.startFailure() { failureRow(failure) }
                    basics
                } header: {
                    Text("Basics", comment: "Settings pane section title: the main settings of a pane")
                        .settingsSectionHeader()
                }
            },
            advanced: { advanced },
            data: { data }
        )
        .destructiveConfirmation(isPresented: $confirmsReset, Self.resetConfirmation) {
            model.actions.enqueue { await model.resetState() }
        }
        .task(id: isActive) {
            guard isActive else { return }
            await model.refresh()
        }
    }

    func label(_ title: Text, help: Text? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            title.font(textSize.font(.body))
            if let help { help.font(textSize.font(.callout)).foregroundStyle(LintelBrand.secondaryText) }
        }
    }

    @ViewBuilder private func failureRow(_ failure: WindowsPlugin.StartError) -> some View {
        switch failure {
        case .unsupported:
            label(
                Text("Update Lintel", comment: "Window Management: the window id function is unavailable"),
                help: Text(
                    "This version of macOS changed something Window Management relies on.",
                    comment: "Window Management: the window id function is unavailable"))
        case .safeMode:
            label(
                Text("Switched off after a problem", comment: "Window Management: safe mode"),
                help: Text(
                    "Windows were left parked twice in a row. Use Try Again above.",
                    comment: "Window Management: safe mode"))
        case .stillStopping:
            label(
                Text("Still stopping", comment: "Window Management: an earlier run has not finished"),
                help: Text(
                    "The windows of the last run are still being put back. Use Try Again above in a moment.",
                    comment: "Window Management: an earlier run has not finished"))
        }
    }

    // MARK: Basics

    @ViewBuilder private var basics: some View {
        LabeledContent {
            Stepper(
                value: Binding(get: { model.workspaceCount }, set: { model.setWorkspaceCount($0) }),
                in: WindowsSettings.minimumWorkspaces...WindowsSettings.maximumWorkspaces
            ) {
                Text("\(model.workspaceCount)").font(textSize.font(.body)).monospacedDigit()
            }
            .accessibilityLabel(Text("Workspaces", comment: "Window Management setting: how many workspaces"))
            .accessibilityValue(Text("\(model.workspaceCount)"))
        } label: {
            label(Text("Workspaces", comment: "Window Management setting: how many workspaces"))
        }
        MenuPicker(selection: Binding(get: { model.defaultKind }, set: { model.setDefaultKind($0) })) {
            ForEach(kindOptions, id: \.self) { kind in
                Text(verbatim: model.kindName(kind)).font(textSize.font(.body)).tag(kind)
            }
        } label: {
            label(
                Text("Default layout", comment: "Window Management setting: how workspaces are arranged"),
                help: Text(
                    "Auto-tile fills the screen with the windows of a workspace. Zones snaps them into zones. Free leaves them where they are.",
                    comment: "Window Management setting help: the layout kinds"))
        }
        LabeledContent {
            Button {
                model.openLayouts()
            } label: {
                Text("Layouts…", comment: "Window Management: opens the Layouts window")
            }
            .disabled(!isActive)
        } label: {
            label(
                Text("Layouts", comment: "Window Management setting: the zone layouts and where they are used"),
                help: Text(verbatim: model.layoutsSummary))
        }
        zoneDefaultRow(
            Text("Zones on landscape displays", comment: "Window Management setting: the default zone layout"),
            orientation: .landscape)
        zoneDefaultRow(
            Text("Zones on portrait displays", comment: "Window Management setting: the default zone layout"),
            orientation: .portrait)
        gapRow(
            Text("Space between windows", comment: "Window Management setting: the inner gap"),
            value: Binding(get: { model.innerGap }, set: { model.setInnerGap($0) }))
        gapRow(
            Text("Space around windows", comment: "Window Management setting: the outer gap"),
            value: Binding(get: { model.outerGap }, set: { model.setOuterGap($0) }))
        Toggle(isOn: Binding(get: { model.stripEnabled }, set: { model.setStripEnabled($0) })) {
            label(Text("Show menu bar strip", comment: "Window Management setting: the numbered boxes in the menu bar"))
        }
        .toggleStyle(.switch)
    }

}
