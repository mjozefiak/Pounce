import LintelKit
import LintelUI
import SwiftUI

/// The pane's per-workspace configuration and its Data group.
extension WindowsSettingsPane {
    // MARK: Per-workspace configuration

    @ViewBuilder var workspaceLayouts: some View {
        label(
            Text("Per-workspace layout", comment: "Window Management setting: the list of per-workspace settings"),
            help: Text(
                "What each workspace uses. Edit one to change its layout and the settings of that layout.",
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

    @ViewBuilder func workspaceEditor(_ workspace: WorkspaceID) -> some View {
        let current = model.override(for: workspace)
        MenuPicker(
            selection: Binding(
                get: { current.kind?.rawValue ?? Self.useDefault },
                set: { model.setOverrideChoice($0, for: workspace) })
        ) {
            Text("Use default", comment: "Window Management: the workspace follows the global setting")
                .font(textSize.font(.body)).tag(Self.useDefault)
            ForEach(model.selectableKinds, id: \.rawValue) { kind in
                Text(verbatim: model.kindName(kind)).font(textSize.font(.body)).tag(kind.rawValue)
            }
        } label: {
            label(Text("Layout", comment: "Window Management: the layout kind of one workspace"))
        }
        // The options of the kind the workspace uses, whichever kind that is.
        ForEach(model.options(of: workspace)) { option in
            optionRow(
                option, value: current.options[option.id], fallback: model.globalValue(of: option)
            ) { model.setOverrideOption(option, to: $0, for: workspace) }
        }
        Button {
            model.resetOverrides(for: workspace)
        } label: {
            Text("Use the defaults for this workspace", comment: "Window Management: clears the overrides")
        }
        .disabled(current.isEmpty)
    }

    static let useDefault = WindowsSettingsModel.useDefaultChoice

    /// One option of a layout kind. With a `fallback` it is a per-workspace override (`value` is the override, if any,
    /// and the row offers the way back to the global value); without one it is the global default itself.
    @ViewBuilder
    func optionRow(
        _ option: LayoutOption, value: JSONValue?, fallback: JSONValue?, set: @escaping (JSONValue?) -> Void
    ) -> some View {
        switch option.domain {
        case .points(let range):
            let shown = Self.number(value ?? fallback ?? option.defaultValue)
            LabeledContent {
                HStack {
                    Stepper(value: Binding(get: { shown }, set: { set(.int($0)) }), in: range) {
                        Text("\(shown) pt", comment: "Window Management: a gap in points")
                            .font(textSize.font(.body)).monospacedDigit()
                    }
                    .accessibilityLabel(Text(verbatim: option.title))
                    .accessibilityValue(Text("\(shown) pt", comment: "Window Management: a gap in points"))
                    if fallback != nil, value != nil {
                        Button {
                            set(nil)
                        } label: {
                            Text("Default", comment: "Window Management: returns a gap to the global value")
                        }
                    }
                }
            } label: {
                label(Text(verbatim: option.title), help: option.help.map { Text(verbatim: $0) })
            }
        case .choices(let choices):
            MenuPicker(
                selection: Binding(
                    get: {
                        value.map(Self.text) ?? (fallback == nil ? Self.text(option.defaultValue) : Self.useDefault)
                    },
                    set: { set($0 == Self.useDefault ? nil : .string($0)) })
            ) {
                if fallback != nil {
                    Text("Use default", comment: "Window Management: the workspace follows the global setting")
                        .font(textSize.font(.body)).tag(Self.useDefault)
                }
                ForEach(choices, id: \.id) { choice in
                    Text(verbatim: choice.title).font(textSize.font(.body)).tag(choice.id)
                }
            } label: {
                label(Text(verbatim: option.title), help: option.help.map { Text(verbatim: $0) })
            }
        }
    }

    private static func number(_ value: JSONValue) -> Int {
        if case .int(let number) = value { return number }
        return 0
    }

    private static func text(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        return ""
    }

    /// A row a strategy adds for a setting of its own (`LayoutSettingRow`): a picker over its choices.
    func strategyRow(_ row: LayoutSettingRow) -> some View {
        MenuPicker(selection: Binding(get: { row.selection() }, set: { row.select($0) })) {
            ForEach(row.choices(), id: \.id) { choice in
                Text(verbatim: choice.title).font(textSize.font(.body)).tag(choice.id)
            }
        } label: {
            label(Text(verbatim: row.title), help: row.help.map { Text(verbatim: $0) })
        }
    }

    // MARK: Data

    @ViewBuilder var data: some View {
        LabeledContent {
            Button {
                model.actions.enqueue { await model.restoreAllWindows() }
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
                model.actions.enqueue { await model.copyDiagnostics() }
            } label: {
                Text(model.copiedDiagnostics ? "Copied" : "Copy", comment: "Window Management: copy diagnostics button")
            }
        } label: {
            label(Text("Copy diagnostics", comment: "Window Management setting: counters for a bug report"))
        }
    }
}
