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

    @ViewBuilder func workspaceEditor(_ workspace: WorkspaceID) -> some View {
        let current = model.override(for: workspace)
        MenuPicker(
            selection: Binding(
                get: { current.kind?.rawValue ?? Self.useDefault },
                set: { model.setOverrideKind(LayoutKind($0), for: workspace) })
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

    static let useDefault = "default"

    func overrideGap(_ title: Text, value: Int?, fallback: Int, set: @escaping (Int?) -> Void)
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
