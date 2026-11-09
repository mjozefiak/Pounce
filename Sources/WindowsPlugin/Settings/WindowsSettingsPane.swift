import LintelKit
import LintelUI
import SwiftUI

/// Settings → Window Management on the `SettingsPane` template (prototype `set-windows`): Basics, a collapsed
/// Advanced and Data. The banner is the host's, from `WindowsPlugin.settingsStatus`. Basics has the default layout
/// and the gaps; the *Layouts…* row of the mockup arrives with phase 3.
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
                    "Windows were left parked twice in a row. Use Try Again above.",
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
            .accessibilityLabel(Text("Workspaces", comment: "Window Management setting: how many workspaces"))
            .accessibilityValue(Text("\(model.workspaceCount)"))
        } label: {
            label(Text("Workspaces", comment: "Window Management setting: how many workspaces"))
        }
        MenuPicker(selection: Binding(get: { model.defaultKind }, set: { model.setDefaultKind($0) })) {
            ForEach(kindOptions, id: \.self) { kind in
                Text(verbatim: WindowsSettingsModel.kindName(kind)).font(textSize.font(.body)).tag(kind)
            }
        } label: {
            label(
                Text("Default layout", comment: "Window Management setting: how workspaces are arranged"),
                help: Text(
                    "Auto-tile fills the screen with the windows of a workspace. Free leaves them where they are.",
                    comment: "Window Management setting help: the layout kinds"))
        }
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
            Text("Go to workspace", comment: "Window Management shortcut family"), family: .goToWorkspace)
        modifierRow(
            Text("Move window to workspace", comment: "Window Management shortcut family"), family: .moveToWorkspace)
        modifierRow(Text("Focus window", comment: "Window Management shortcut family"), family: .focus)
        modifierRow(Text("Move window", comment: "Window Management shortcut family"), family: .moveWindow)
        modifierRow(Text("Resize window", comment: "Window Management shortcut family"), family: .resize)
        if model.modifierConflict {
            label(
                Text(
                    "Use different modifiers for the two shortcut families.",
                    comment: "Window Management shortcut rows: the other family already uses this choice"))
        }
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
        workspaceLayouts
        floatingApps
    }

    private func modifierRow(_ title: Text, family: ShortcutFamily) -> some View {
        let choice = model.choices[family]
        return MenuPicker(
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
                Text(verbatim: option.symbols + family.keysLabel).font(textSize.font(.body)).tag(option.rawValue)
                    .disabled(option == model.partnerChoice(of: family))
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
                .accessibilityLabel(
                    Text(
                        "Remove \(model.appName(bundleID))",
                        comment: "Window Management: removes one app from the floating list (spoken)"))
            } label: {
                Text(verbatim: model.appName(bundleID)).font(textSize.font(.callout))
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

    private var kindOptions: [LayoutKind] {
        WindowsSettingsModel.selectableKinds
            + (WindowsSettingsModel.selectableKinds.contains(model.defaultKind) ? [] : [model.defaultKind])
    }

    private func gapRow(_ title: Text, value: Binding<Int>) -> some View {
        LabeledContent {
            Stepper(value: value, in: 0...WindowsSettings.maximumGap) {
                Text("\(value.wrappedValue) pt", comment: "Window Management: a gap in points").font(
                    textSize.font(.body)
                )
                .monospacedDigit()
            }
            .accessibilityLabel(title)
            .accessibilityValue(Text("\(value.wrappedValue) pt", comment: "Window Management: a gap in points"))
        } label: {
            label(title)
        }
    }

    // MARK: Per-workspace configuration

    @ViewBuilder private var workspaceLayouts: some View {
        label(
            Text("Per-workspace layout", comment: "Window Management setting: the list of per-workspace settings"),
            help: Text(
                "What each workspace uses. Edit one to change its layout, gaps or first split.",
                comment: "Window Management setting help: per-workspace layout"))
        if model.overridesLocked {
            label(
                Text(
                    "These settings were saved by a newer version of Lintel and can’t be changed here.",
                    comment: "Window Management: per-workspace settings from a newer version"))
        }
        ForEach(model.workspaceSummaries) { line in
            LabeledContent {
                Button {
                    model.edit(line.workspace)
                } label: {
                    Text(
                        model.editingWorkspace == line.workspace ? "Done" : "Edit",
                        comment: "Window Management: edits the layout of one workspace")
                }
                .disabled(model.overridesLocked)
                .accessibilityLabel(
                    Text(
                        "Edit workspace \(line.workspace.rawValue)",
                        comment: "Window Management: edits one workspace (spoken)"))
            } label: {
                label(
                    Text("Workspace \(line.workspace.rawValue)", comment: "Window switcher: a workspace"),
                    help: Text(verbatim: line.detail))
            }
            if model.editingWorkspace == line.workspace { workspaceEditor(line.workspace) }
        }
    }

    @ViewBuilder private func workspaceEditor(_ workspace: WorkspaceID) -> some View {
        let current = model.override(for: workspace)
        MenuPicker(
            selection: Binding(
                get: { current.kind?.rawValue ?? Self.useDefault },
                set: { model.setOverrideKind(LayoutKind(rawValue: $0), for: workspace) })
        ) {
            Text("Use default", comment: "Window Management: the workspace follows the global setting")
                .font(textSize.font(.body)).tag(Self.useDefault)
            ForEach(WindowsSettingsModel.selectableKinds, id: \.rawValue) { kind in
                Text(verbatim: WindowsSettingsModel.kindName(kind)).font(textSize.font(.body)).tag(kind.rawValue)
            }
        } label: {
            label(Text("Layout", comment: "Window Management: the layout kind of one workspace"))
        }
        overrideGap(
            Text("Space between windows", comment: "Window Management setting: the inner gap"), value: current.innerGap,
            fallback: model.innerGap
        ) { model.setOverrideInnerGap($0, for: workspace) }
        overrideGap(
            Text("Space around windows", comment: "Window Management setting: the outer gap"), value: current.outerGap,
            fallback: model.outerGap
        ) { model.setOverrideOuterGap($0, for: workspace) }
        MenuPicker(
            selection: Binding(
                get: { current.rootOrientation?.rawValue ?? Self.useDefault },
                set: { model.setOverrideOrientation(TilingOrientation(rawValue: $0), for: workspace) })
        ) {
            Text("Use default", comment: "Window Management: the workspace follows the global setting")
                .font(textSize.font(.body)).tag(Self.useDefault)
            ForEach(TilingOrientation.allCases, id: \.rawValue) { orientation in
                Text(verbatim: WindowsSettingsModel.orientationName(orientation)).font(textSize.font(.body))
                    .tag(orientation.rawValue)
            }
        } label: {
            label(Text("First split", comment: "Window Management: the root orientation of one workspace"))
        }
        Button {
            model.resetOverrides(for: workspace)
        } label: {
            Text("Use the defaults for this workspace", comment: "Window Management: clears the overrides")
        }
        .disabled(current.isEmpty)
    }

    private static let useDefault = "default"

    private func overrideGap(_ title: Text, value: Int?, fallback: Int, set: @escaping (Int?) -> Void)
        -> some View
    {
        LabeledContent {
            HStack {
                Stepper(
                    value: Binding(get: { value ?? fallback }, set: { set($0) }),
                    in: 0...WindowsSettings.maximumGap
                ) {
                    Text("\(value ?? fallback) pt", comment: "Window Management: a gap in points")
                        .font(textSize.font(.body)).monospacedDigit()
                }
                .accessibilityLabel(title)
                if value != nil {
                    Button {
                        set(nil)
                    } label: {
                        Text("Default", comment: "Window Management: returns a gap to the global value")
                    }
                }
            }
        } label: {
            label(title)
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
