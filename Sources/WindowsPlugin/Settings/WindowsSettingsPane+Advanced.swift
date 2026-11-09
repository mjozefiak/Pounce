import LintelKit
import LintelUI
import SwiftUI

/// The pane's Advanced group: focus, HUD, strip, shortcut modifiers and the zone layout defaults.
extension WindowsSettingsPane {
    // MARK: Advanced

    @ViewBuilder var advanced: some View {
        Toggle(isOn: Binding(get: { model.followFocus }, set: { model.setFollowFocus($0) })) {
            label(
                Text("Jump to a window’s workspace", comment: "Window Management setting: follow focus"),
                help: Text(
                    "Switch when a window in another workspace gets focus.",
                    comment: "Window Management setting help: follow focus"))
        }
        .toggleStyle(.switch)
        Toggle(isOn: Binding(get: { model.showHUD }, set: { model.setShowHUD($0) })) {
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
        layoutSlots
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

    func modifierRow(_ title: Text, family: ShortcutFamily) -> some View {
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

    @ViewBuilder var floatingApps: some View {
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

    /// The nine layout slots (spec: API Contracts): each is a command with its own shortcut and is bound to a
    /// layout here, so deleting a layout never leaves a shortcut that points nowhere.
    @ViewBuilder var layoutSlots: some View {
        label(
            Text("Layout slots", comment: "Window Management setting: nine shortcuts that each apply a layout"),
            help: Text(
                "Each slot has its own shortcut and applies the layout you bind to it to the current workspace.",
                comment: "Window Management setting help: layout slots"))
        ForEach(1...LayoutRules.slotCount, id: \.self) { number in
            HStack {
                MenuPicker(
                    selection: Binding(
                        get: { model.layoutSlots[number] ?? Self.useDefault },
                        set: { value in
                            model.actions.enqueue {
                                await model.setLayoutSlot(number, to: value == Self.useDefault ? nil : value)
                            }
                        })
                ) {
                    Text("None", comment: "Window Management: a layout slot that is not bound")
                        .font(textSize.font(.body)).tag(Self.useDefault)
                    ForEach(model.allLayouts, id: \.id) { layout in
                        Text(verbatim: StockLayouts.displayName(of: layout)).font(textSize.font(.body)).tag(layout.id)
                    }
                } label: {
                    Text("Layout slot \(number)", comment: "Layouts window: a numbered shortcut slot")
                        .font(textSize.font(.body))
                }
                .disabled(model.libraryLocked)
                model.context.makeShortcutRecorder(WindowsCommandID.layoutSlot(number))
            }
        }
    }

    /// The default zone layout of displays of one shape: a stock layout.
    func zoneDefaultRow(_ title: Text, orientation: DisplayOrientation) -> some View {
        MenuPicker(
            selection: Binding(
                get: { model.defaultZoneLayout(for: orientation) },
                set: { model.setDefaultZoneLayout($0, for: orientation) })
        ) {
            ForEach(model.allLayouts, id: \.id) { layout in
                Text(verbatim: StockLayouts.displayName(of: layout)).font(textSize.font(.body)).tag(layout.id)
            }
            // A default that is in no library (deleted, or from a later version) stays selectable as it is.
            if !model.allLayouts.contains(where: { $0.id == model.defaultZoneLayout(for: orientation) }) {
                Text(verbatim: model.defaultZoneLayout(for: orientation)).font(textSize.font(.body))
                    .tag(model.defaultZoneLayout(for: orientation))
            }
        } label: {
            label(
                title,
                help: Text(
                    "Used when a display has no layout of its own for a workspace.",
                    comment: "Window Management setting help: the default zone layout"))
        }
    }

    var kindOptions: [LayoutKind] {
        WindowsSettingsModel.selectableKinds
            + (WindowsSettingsModel.selectableKinds.contains(model.defaultKind) ? [] : [model.defaultKind])
    }

    func gapRow(_ title: Text, value: Binding<Int>) -> some View {
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
}
