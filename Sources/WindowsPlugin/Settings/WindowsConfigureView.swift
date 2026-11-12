import LintelKit
import LintelUI
import SwiftUI

/// The Configure window's content: a sidebar (Shortcuts, Workspaces, Gaps & Layout) and the section beside it.
/// Colours are the brand's warm neutrals; type follows the app's text size.
struct WindowsConfigureView: View {
    @Bindable var model: WindowsConfigureModel
    @Environment(\.lintelTextSize) var textSize
    @State var confirmsResetAll = false

    static let resetAllConfirmation = DestructiveConfirmation(
        prompt: LocalizedStringResource("Reset all shortcuts?", comment: "Configure: confirmation title"),
        detail: LocalizedStringResource("This can’t be undone.", comment: "Configure: confirmation text"),
        confirmTitle: LocalizedStringResource("Reset All", comment: "Configure: confirmation button"))

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 180)
                .background(LintelBrand.sidebarBackground)
            LintelDivider(axis: .vertical)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LintelBrand.windowBackground)
        }
        .frame(minWidth: 640, minHeight: 420)
        .destructiveConfirmation(isPresented: $confirmsResetAll, Self.resetAllConfirmation) { model.resetAll() }
        .task {
            // The shell's recorders write the shortcuts themselves, so the list reads them again while it is open.
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(WindowsConfigureModel.Section.allCases) { section in
                Button {
                    model.section = section
                } label: {
                    Text(section.title).font(textSize.font(.body))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(
                            model.section == section ? LintelBrand.windowSelectionTint : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.section == section ? .isSelected : [])
            }
            Spacer()
        }
        .padding(10)
    }

    @ViewBuilder private var content: some View {
        switch model.section {
        case .shortcuts: shortcuts
        case .workspaces: workspaces
        case .gapsAndLayout: gapsAndLayout
        case .rules: rules
        }
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField(text: $model.query) {
                    Text("Search shortcuts", comment: "Configure: search field of the shortcut list")
                }
                .textFieldStyle(.roundedBorder)
                Button {
                    confirmsResetAll = true
                } label: {
                    Text("Reset All to Defaults…", comment: "Configure: resets every shortcut")
                }
            }
            .padding(12)
            LintelDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.flaggedCount > 0 && !model.searching { flaggedBanner }
                    if !model.searching { modifierRows }
                    ForEach(model.visibleGroups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title).font(textSize.font(.callout)).foregroundStyle(LintelBrand.secondaryText)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(model.rows(in: group)) { row in shortcutRow(row) }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var flaggedBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LintelBrand.statusAttention)
                .accessibilityHidden(true)
            Text(ShortcutWarning.title(count: model.flaggedCount)).font(textSize.font(.body))
            Spacer()
            Button {
                model.pane.useControlOption()
                model.refresh()
            } label: {
                Text(ShortcutWarning.action)
            }
        }
    }

    /// One *Modifiers* row for each numbered family (the digits stay fixed).
    @ViewBuilder private var modifierRows: some View {
        ForEach(model.modifierFamilies, id: \.self) { family in
            let choice = model.pane.choices[family]
            MenuPicker(
                selection: Binding(
                    get: { choice?.rawValue ?? "custom" },
                    set: {
                        if let value = ModifierChoice(rawValue: $0) {
                            model.pane.setModifiers(value, for: family)
                            model.refresh()
                        }
                    })
            ) {
                if choice == nil {
                    Group {
                        if model.pane.mixedFamilies.contains(family) {
                            Text(
                                "Mixed", comment: "Window Management shortcut modifiers: the family's shortcuts differ")
                        } else {
                            Text("Custom", comment: "Window Management shortcut modifiers: recorded by hand")
                        }
                    }
                    .tag("custom")
                }
                ForEach(ModifierChoice.allCases) { option in
                    Text(verbatim: option.symbols + family.keysLabel).tag(option.rawValue)
                        .disabled(option == model.pane.partnerChoice(of: family))
                }
            } label: {
                HStack(spacing: 4) {
                    family.title
                    Text("Modifiers", comment: "Configure: the modifier keys of a numbered family")
                        .foregroundStyle(LintelBrand.secondaryText)
                }
                .font(textSize.font(.body))
            }
        }
    }

    private func shortcutRow(_ row: WindowsConfigureModel.ShortcutRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: row.title).font(textSize.font(.body))
                if row.typesCharacter {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LintelBrand.statusAttention)
                        .help(
                            Text(
                                "This shortcut types a character on your keyboard.",
                                comment: "Configure: tooltip of the warning icon of a shortcut")
                        )
                        .accessibilityLabel(
                            Text(
                                "Types a character on your keyboard",
                                comment: "Configure: spoken warning of a shortcut that types a character"))
                }
                Spacer()
                model.pane.context.makeShortcutRecorder(row.id)
                if !row.isDefault {
                    Button {
                        model.reset(row.id)
                    } label: {
                        Text("Reset", comment: "Configure: puts one shortcut back to its default")
                    }
                    .accessibilityLabel(
                        Text(
                            "Reset \(row.title)",
                            comment: "Configure: puts one shortcut back to its default (spoken)"))
                }
            }
            if let conflict = row.conflict {
                HStack {
                    Text("Also used by \(conflict)", comment: "Configure: another command has the same shortcut")
                        .font(textSize.font(.callout)).foregroundStyle(LintelBrand.statusAttention)
                    Button {
                        model.replaceConflict(of: row.id)
                    } label: {
                        Text("Replace", comment: "Configure: takes the shortcut from the other command")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Workspaces

    private var workspaces: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.namesLocked || model.pane.overridesLocked {
                    Text(
                        "Some of these settings were saved by a newer version of Lintel and can’t be changed here.",
                        comment: "Configure: workspace settings from a newer version"
                    )
                    .font(textSize.font(.callout)).foregroundStyle(LintelBrand.secondaryText)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        header("Workspace", "Configure: workspace table column")
                        header("Name", "Configure: workspace table column")
                        header("Layout", "Configure: workspace table column")
                        header("Gaps", "Configure: workspace table column")
                        header("Direction", "Configure: workspace table column")
                    }
                    ForEach(model.workspaces, id: \.self) { workspace in
                        GridRow {
                            Text("\(workspace.rawValue)").font(textSize.font(.body)).monospacedDigit()
                            NameField(model: model, workspace: workspace)
                            kindPicker(workspace)
                            gapsPicker(workspace)
                            directionPicker(workspace)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func header(_ title: LocalizedStringResource, _ comment: StaticString) -> some View {
        Text(title).font(textSize.font(.callout)).foregroundStyle(LintelBrand.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    private func kindPicker(_ workspace: WorkspaceID) -> some View {
        Picker(
            selection: Binding(
                get: { model.kindChoice(of: workspace) },
                set: { model.pane.setOverrideChoice($0, for: workspace) })
        ) {
            Text(
                "Default · \(model.pane.kindName(model.pane.defaultKind))",
                comment: "Configure: the workspace follows the default layout"
            ).tag(WindowsSettingsModel.useDefaultChoice)
            ForEach(model.pane.selectableKinds, id: \.rawValue) { kind in
                Text(verbatim: model.pane.kindName(kind)).tag(kind.rawValue)
            }
        } label: {
            Text("Layout of workspace \(workspace.rawValue)", comment: "Configure: spoken name of the layout picker")
        }
        .labelsHidden().pickerStyle(.menu).disabled(model.pane.overridesLocked)
    }

    private func gapsPicker(_ workspace: WorkspaceID) -> some View {
        let choices = [0, 5, 10, 15, 20, 30]
        return Picker(
            selection: Binding(
                get: { model.gapsValue(of: workspace).map(String.init) ?? WindowsSettingsModel.useDefaultChoice },
                set: { model.setGaps(Int($0), for: workspace) })
        ) {
            Text(verbatim: model.gapsSummary(of: workspace)).tag(
                model.gapsValue(of: workspace) == nil ? WindowsSettingsModel.useDefaultChoice : "unused")
            ForEach(choices, id: \.self) { Text("\($0) pt").tag(String($0)) }
        } label: {
            Text("Gaps of workspace \(workspace.rawValue)", comment: "Configure: spoken name of the gaps picker")
        }
        .labelsHidden().pickerStyle(.menu).disabled(model.pane.overridesLocked)
    }

    @ViewBuilder private func directionPicker(_ workspace: WorkspaceID) -> some View {
        if let option = model.orientationOption(of: workspace), case .choices(let choices) = option.domain {
            Picker(
                selection: Binding(
                    get: { model.orientationChoice(of: workspace) },
                    set: { model.setOrientation($0, for: workspace) })
            ) {
                Text("Default", comment: "Configure: the workspace follows the default value")
                    .tag(WindowsSettingsModel.useDefaultChoice)
                ForEach(choices, id: \.id) { Text(verbatim: $0.title).tag($0.id) }
            } label: {
                Text(
                    "Direction of workspace \(workspace.rawValue)",
                    comment: "Configure: spoken name of the direction picker")
            }
            .labelsHidden().pickerStyle(.menu).disabled(model.pane.overridesLocked)
        } else {
            Text("—").foregroundStyle(LintelBrand.secondaryText).accessibilityHidden(true)
        }
    }

    // MARK: Rules

    private var rules: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Rules apply when a window is created. Float keeps an app’s windows where they are; a workspace rule starts its new windows there.",
                    comment: "Configure: what app rules do"
                )
                .font(textSize.font(.callout)).foregroundStyle(LintelBrand.secondaryText)
                if model.rulesLocked {
                    Text(
                        "Some rules were saved by a newer version of Lintel and can’t be changed here.",
                        comment: "Configure: app rules from a newer version"
                    )
                    .font(textSize.font(.callout)).foregroundStyle(LintelBrand.secondaryText)
                }
                ForEach(model.ruleRows) { row in ruleRow(row) }
                Menu {
                    ForEach(model.appCandidates(), id: \.bundleID) { app in
                        Button(app.name) { model.addRule(bundleID: app.bundleID, .float) }
                    }
                    Divider()
                    Button {
                        if let bundleID = model.pane.pickApp() { model.addRule(bundleID: bundleID, .float) }
                    } label: {
                        Text("Choose…", comment: "Configure: picks an app from /Applications for a rule")
                    }
                } label: {
                    Text("Add App", comment: "Configure: adds an app to the rules")
                }
                .fixedSize()
            }
            .padding(16)
        }
    }

    private func ruleRow(_ row: WindowsConfigureModel.RuleRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.name).font(textSize.font(.body))
                if row.isInactive, case .workspace(let number) = row.choice {
                    Text("Workspace \(number) is off", comment: "Configure: a rule points to a workspace that is off")
                        .font(textSize.font(.callout)).foregroundStyle(LintelBrand.statusAttention)
                }
            }
            Spacer()
            Picker(
                selection: Binding(
                    get: { row.choice.tag },
                    set: { tag in
                        if let choice = WindowsConfigureModel.RuleChoice(tag: tag) {
                            model.setRule(choice, for: row.bundleID)
                        }
                    })
            ) {
                Text("Float", comment: "Configure: the app's windows are never arranged").tag("float")
                ForEach(1...WindowsSettings.maximumWorkspaces, id: \.self) { number in
                    Text("Workspace \(number)", comment: "Window switcher: a workspace").tag("ws\(number)")
                }
            } label: {
                Text("Rule for \(row.name)", comment: "Configure: spoken name of the rule picker of an app")
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            Button {
                model.removeRule(row.bundleID)
            } label: {
                Text("Remove", comment: "Window Management: removes an app from the floating list")
            }
            .accessibilityLabel(
                Text(
                    "Remove \(row.name)", comment: "Window Management: removes one app from the floating list (spoken)")
            )
        }
    }

    // MARK: Gaps and layout

    private var gapsAndLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MenuPicker(
                    selection: Binding(
                        get: { model.pane.defaultKind }, set: { model.pane.setDefaultKind($0) })
                ) {
                    ForEach(model.pane.selectableKinds, id: \.self) { kind in
                        Text(verbatim: model.pane.kindName(kind)).tag(kind)
                    }
                } label: {
                    Text("Default layout", comment: "Window Management setting: how workspaces are arranged")
                }
                ForEach(model.globalOptions) { option in
                    if case .points(let range) = option.domain {
                        let value = Binding(
                            get: {
                                if case .int(let number) = model.pane.globalValue(of: option) { return number }
                                return range.lowerBound
                            },
                            set: { model.pane.setGlobalValue(.int($0), of: option) })
                        LabeledContent {
                            Stepper(value: value, in: range) {
                                Text("\(value.wrappedValue) pt").font(textSize.font(.body)).monospacedDigit()
                            }
                            .accessibilityLabel(Text(verbatim: option.title))
                        } label: {
                            Text(verbatim: option.title).font(textSize.font(.body))
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

/// A name field that writes when the user leaves it or presses Return, not on every key (a name is trimmed when it
/// is stored, so writing per key would eat a space typed between two words).
private struct NameField: View {
    let model: WindowsConfigureModel
    let workspace: WorkspaceID
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(text: $text) {
            Text("Name of workspace \(workspace.rawValue)", comment: "Configure: spoken name of a workspace name field")
        }
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 120)
        .focused($focused)
        .disabled(model.namesLocked)
        .onSubmit(commit)
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        .onAppear { text = model.name(of: workspace) }
        .onDisappear(perform: commit)
        .onChange(of: text) { _, new in
            if new.count > WorkspaceNames.maximumLength { text = String(new.prefix(WorkspaceNames.maximumLength)) }
        }
    }

    private func commit() {
        guard text != model.name(of: workspace) else { return }
        model.setName(text, for: workspace)
        text = model.name(of: workspace)
    }
}

extension WindowsConfigureModel.Section {
    var title: LocalizedStringResource {
        switch self {
        case .shortcuts: LocalizedStringResource("Shortcuts", comment: "Configure: sidebar section")
        case .workspaces: LocalizedStringResource("Workspaces", comment: "Configure: sidebar section")
        case .gapsAndLayout: LocalizedStringResource("Gaps & Layout", comment: "Configure: sidebar section")
        case .rules: LocalizedStringResource("Rules", comment: "Configure: sidebar section")
        }
    }
}

extension WindowsConfigureModel.Group {
    var title: LocalizedStringResource {
        switch self {
        case .workspaces: LocalizedStringResource("Workspaces", comment: "Configure: group of shortcuts")
        case .focus: LocalizedStringResource("Focus", comment: "Configure: group of shortcuts")
        case .move: LocalizedStringResource("Move", comment: "Configure: group of shortcuts")
        case .layout: LocalizedStringResource("Layout", comment: "Configure: group of shortcuts")
        case .resize: LocalizedStringResource("Resize", comment: "Configure: group of shortcuts")
        case .display: LocalizedStringResource("Display", comment: "Configure: group of shortcuts")
        case .other: LocalizedStringResource("Other", comment: "Configure: group of shortcuts")
        }
    }
}
