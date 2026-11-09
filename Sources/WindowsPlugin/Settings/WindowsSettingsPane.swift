import LintelKit
import LintelUI
import SwiftUI

/// Settings → Window Management on the `SettingsPane` template (prototype `set-windows`): Basics, a collapsed
/// Advanced and Data. The banner is the host's, from `WindowsPlugin.settingsStatus`. The layout rows of the
/// mockup (default layout, gaps, Layouts…) arrive with the phases that build them.
struct WindowsSettingsPane: View {
    @Bindable var model: WindowsSettingsModel
    /// `false` while the plugin is off or failed: the pane then reads nothing and starts nothing.
    var isActive = true

    @Environment(\.lintelTextSize) private var textSize
    @State private var confirmsReset = false

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
            Task { await model.resetState() }
        }
        .task(id: isActive) {
            guard isActive else { return }
            await model.refresh()
        }
    }

    private func label(_ title: Text, help: Text? = nil) -> some View {
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
                    "Windows were left parked twice in a row. Try Again starts it.",
                    comment: "Window Management: safe mode"))
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
        } label: {
            label(Text("Workspaces", comment: "Window Management setting: how many workspaces"))
        }
        Toggle(isOn: Binding(get: { model.stripEnabled }, set: { model.setStripEnabled($0) })) {
            label(Text("Show menu bar strip", comment: "Window Management setting: the numbered boxes in the menu bar"))
        }
        .toggleStyle(.switch)
    }

    // MARK: Advanced

    @ViewBuilder private var advanced: some View {
        Toggle(isOn: Binding(get: { model.followFocus }, set: { model.setFollowFocus($0) })) {
            label(
                Text("Jump to a window’s workspace", comment: "Window Management setting: follow focus"),
                help: Text(
                    "Switch when a window in another workspace gets focus.",
                    comment: "Window Management setting help: follow focus"))
        }
        .toggleStyle(.switch)
        Toggle(isOn: Binding(get: { model.workspaceHUD }, set: { model.setWorkspaceHUD($0) })) {
            label(Text("Show a number after switching", comment: "Window Management setting: the workspace HUD"))
        }
        .toggleStyle(.switch)
        MenuPicker(selection: Binding(get: { model.stripMode }, set: { model.setStripMode($0) })) {
            Text("All workspaces", comment: "Window Management strip mode").font(textSize.font(.body)).tag(
                WindowsSettings.StripMode.all)
            Text("Only workspaces with windows", comment: "Window Management strip mode").font(textSize.font(.body))
                .tag(WindowsSettings.StripMode.occupied)
        } label: {
            label(Text("Strip shows", comment: "Window Management setting: which boxes the strip draws"))
        }
        modifierRow(
            Text("Go to workspace", comment: "Window Management shortcut family"), family: .goToWorkspace,
            choice: model.goChoice)
        modifierRow(
            Text("Move window to workspace", comment: "Window Management shortcut family"), family: .moveToWorkspace,
            choice: model.moveChoice)
        if model.needsShortcutWarning {
            HStack {
                label(
                    Text("Some shortcuts type letters", comment: "Window Management shortcut warning"),
                    help: Text(
                        "On this keyboard layout \(model.unsafeKeyNames) types a character.",
                        comment: "Window Management shortcut warning: names the keys"))
                Spacer()
                Button {
                    model.useControlOption()
                } label: {
                    Text("Use ⌃⌥", comment: "Window Management shortcut warning button")
                }
            }
        }
        floatingApps
    }

    private func modifierRow(_ title: Text, family: ShortcutFamily, choice: ModifierChoice?) -> some View {
        MenuPicker(
            selection: Binding(
                get: { choice?.rawValue ?? "custom" },
                set: { if let value = ModifierChoice(rawValue: $0) { model.setModifiers(value, for: family) } })
        ) {
            if choice == nil {
                Text("Custom", comment: "Window Management shortcut modifiers: recorded by hand").font(
                    textSize.font(.body)
                ).tag("custom")
            }
            ForEach(ModifierChoice.allCases) { option in
                Text(verbatim: option.symbols + "1–9").font(textSize.font(.body)).tag(option.rawValue)
            }
        } label: {
            label(title)
        }
    }

    @ViewBuilder private var floatingApps: some View {
        label(
            Text("Floating apps", comment: "Window Management setting: apps that are never arranged"),
            help: Text(
                "These apps keep their windows where they are.", comment: "Window Management setting help"))
        ForEach(model.floatingApps, id: \.self) { bundleID in
            LabeledContent {
                Button {
                    model.removeFloatingApp(bundleID)
                } label: {
                    Text("Remove", comment: "Window Management: removes an app from the floating list")
                }
            } label: {
                Text(verbatim: bundleID).font(textSize.font(.callout))
            }
        }
        HStack {
            Button {
                model.addFloatingApp()
            } label: {
                Text("Add App…", comment: "Window Management: adds an app to the floating list")
            }
            Button {
                model.resetFloatingApps()
            } label: {
                Text("Reset List", comment: "Window Management: restores the default floating apps")
            }
        }
    }

    // MARK: Data

    @ViewBuilder private var data: some View {
        LabeledContent {
            Button {
                Task { await model.restoreAllWindows() }
            } label: {
                Text("Restore", comment: "Window Management: restore button")
            }
        } label: {
            label(
                Text("Restore all windows", comment: "Window Management setting: puts every parked window back"),
                help: Text("Puts every parked window back on screen.", comment: "Window Management setting help"))
        }
        LabeledContent {
            Button(role: .destructive) {
                confirmsReset = true
            } label: {
                Text("Reset", comment: "Window Management: reset button")
            }
        } label: {
            label(Text("Reset state…", comment: "Window Management setting: forgets the workspaces"))
        }
        LabeledContent {
            Button {
                Task { await model.copyDiagnostics() }
            } label: {
                Text(model.copiedDiagnostics ? "Copied" : "Copy", comment: "Window Management: copy diagnostics button")
            }
        } label: {
            label(Text("Copy diagnostics", comment: "Window Management setting: counters for a bug report"))
        }
    }
}
