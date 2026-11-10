import Foundation
import LintelKit

/// One line of the per-workspace summary in Advanced ("Workspace 3: Free · gaps 0 / 8").
struct WorkspaceSummaryLine: Identifiable, Equatable {
    var workspace: WorkspaceID
    var detail: String
    /// Whether any of the workspace's settings overrides a global default.
    var isCustom: Bool

    var id: Int { workspace.rawValue }
}

/// The layout rows of the pane: the default kind, the gaps and the per-workspace overrides (spec: Q17).
extension WindowsSettingsModel {
    /// The kinds the user can choose: every registered strategy, in registration order.
    var selectableKinds: [LayoutKind] { registry.kinds }

    /// The name of a kind as its strategy gives it; a kind with no strategy shows its identifier.
    func kindName(_ kind: LayoutKind) -> String { registry[kind]?.displayName ?? kind.rawValue }

    // MARK: Defaults

    func setDefaultKind(_ kind: LayoutKind) {
        settings.setDefaultKind(kind)
        defaultKind = kind
        applyLayoutChange()
    }

    /// The default zone layout of displays of one shape (spec Q19), by stock layout id.
    func defaultZoneLayout(for orientation: DisplayOrientation) -> String {
        settings.defaultZoneLayout(for: orientation)
    }

    func setDefaultZoneLayout(_ layoutID: String, for orientation: DisplayOrientation) {
        settings.setDefaultZoneLayout(layoutID, for: orientation)
        applyLayoutChange()
    }

    /// Every layout a default or a slot can name: the stock templates, then the user's.
    var allLayouts: [GridLayout] { StockLayouts.all + libraryLayouts }

    /// Reads the library again (the pane appeared, or the Layouts window changed it). Nothing while the plugin
    /// is off.
    func reloadLibrary() async {
        guard let running = runtime() else {
            libraryLayouts = []
            layoutSlots = [:]
            libraryLocked = false
            return
        }
        let snapshot = await running.layouts.snapshot
        libraryLayouts = snapshot.user
        layoutSlots = snapshot.slots
        libraryLocked = snapshot.isReadOnly
    }

    /// Binds a layout slot to a layout, or frees it with `nil` (the pane's slot rows).
    func setLayoutSlot(_ number: Int, to layoutID: String?) async {
        guard let running = runtime(), !libraryLocked else { return }
        do {
            try await running.layouts.setSlot(number, to: layoutID)
        } catch {
            running.context.logger.error("Cannot write layouts.json")
        }
        await reloadLibrary()
    }

    /// "6 layouts · Zones: 2 workspaces": the line under *Layouts…* in Basics.
    var layoutsSummary: String {
        let layouts = String(
            localized: "\(StockLayouts.all.count + libraryLayouts.count) layouts",
            comment: "Settings: how many zone layouts exist")
        let config = layoutConfig
        // Every kind that assigns layouts from the library is counted.
        let usage = registry.libraryKinds.map { kind -> String in
            let name = kindName(kind)
            let count = WorkspaceID.all(count: workspaceCount).filter { config.resolved(for: $0).kind == kind }.count
            let used =
                count == 0
                ? String(localized: "no workspaces", comment: "Settings: no workspace uses the layout kind")
                : String(
                    localized: "\(count) workspaces",
                    comment: "Settings: how many workspaces use a layout kind (after the kind's name)")
            return String(
                localized: "\(name): \(used)", comment: "Settings: a layout kind's name and how many workspaces use it")
        }
        return ([layouts] + usage).joined(separator: " · ")
    }

    // MARK: Options

    /// The options the pane draws for global defaults: those of every registered kind that name a setting.
    var globalOptionRows: [LayoutOption] {
        registry.kinds.flatMap { registry[$0]?.options ?? [] }.filter { $0.settingKey != nil }
    }

    /// The options of the kind a workspace uses (its override, else the default).
    func options(of workspace: WorkspaceID) -> [LayoutOption] {
        registry[layoutConfig.resolved(for: workspace).kind]?.options ?? []
    }

    static func globalOptions(_ settings: WindowsSettings, _ registry: LayoutRegistry) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for kind in registry.kinds {
            for option in registry[kind]?.options ?? [] { values[option.id] = settings.globalValue(of: option) }
        }
        return values
    }

    func globalValue(of option: LayoutOption) -> JSONValue { globalOptions[option.id] ?? option.defaultValue }

    func setGlobalValue(_ value: JSONValue, of option: LayoutOption) {
        settings.setGlobalValue(value, of: option)
        globalOptions[option.id] = settings.globalValue(of: option)
        applyLayoutChange()
    }

    /// The rows the strategies add for their own settings (`SettingRowProviding`).
    var strategySettingRows: [LayoutSettingRow] {
        let context = LayoutSettingsContext(
            settings: settings, layouts: { [weak self] in self?.allLayouts ?? [] },
            apply: { [weak self] in self?.applyLayoutChange() })
        return registry.kinds.flatMap { registry[$0]?.settingRows?.settingRows(context) ?? [] }
    }

    // MARK: Summary

    /// The effective configuration of every workspace, so what the engine uses is always readable.
    var workspaceSummaries: [WorkspaceSummaryLine] {
        let config = layoutConfig
        return WorkspaceID.all(count: workspaceCount).map { workspace in
            let resolved = config.resolved(for: workspace)
            let parts = [kindName(resolved.kind)] + (registry[resolved.kind]?.summaryParts(resolved) ?? [])
            return WorkspaceSummaryLine(
                workspace: workspace, detail: parts.joined(separator: " · "),
                isCustom: !(overrides.byWorkspace[workspace]?.isEmpty ?? true))
        }
    }

    /// The defaults and the overrides as the engine receives them: the same construction the engine's
    /// configuration uses, over the overrides this model holds.
    var layoutConfig: LayoutConfig {
        LayoutConfig(settings: settings, registry: registry, overrides: overrides.byWorkspace)
    }

    // MARK: Overrides

    func edit(_ workspace: WorkspaceID?) {
        editingWorkspace = editingWorkspace == workspace ? nil : workspace
    }

    func override(for workspace: WorkspaceID) -> WorkspaceOverride {
        overrides.byWorkspace[workspace] ?? WorkspaceOverride()
    }

    /// Whether the stored overrides come from a newer version and cannot be changed here.
    var overridesLocked: Bool { overrides.isReadOnly }

    /// The picker's tag for "use the default" (it is not a kind: choosing it clears the override).
    static let useDefaultChoice = WorkspaceOverrides.useDefaultKindName

    /// A choice of the kind picker: a kind id, or `useDefaultChoice`, which stores no kind at all.
    func setOverrideChoice(_ choice: String, for workspace: WorkspaceID) {
        setOverrideKind(choice == Self.useDefaultChoice ? nil : LayoutKind(choice), for: workspace)
    }

    func setOverrideKind(_ kind: LayoutKind?, for workspace: WorkspaceID) {
        update(workspace) { $0.kind = kind }
    }

    /// Sets (or, with `nil`, clears) the override of one option of a workspace's kind.
    func setOverrideOption(_ option: LayoutOption, to value: JSONValue?, for workspace: WorkspaceID) {
        update(workspace) { $0.options[option.id] = value.flatMap { option.valid($0) } }
    }

    func resetOverrides(for workspace: WorkspaceID) {
        update(workspace) { $0 = WorkspaceOverride() }
    }

    private func update(_ workspace: WorkspaceID, _ change: (inout WorkspaceOverride) -> Void) {
        guard !overrides.isReadOnly else { return }
        var next = overrides
        var entry = next.byWorkspace[workspace] ?? WorkspaceOverride()
        change(&entry)
        next.byWorkspace[workspace] = entry.isEmpty ? nil : entry
        guard settings.setWorkspaceOverrides(next) else { return }
        overrides = next
        applyLayoutChange()
    }

    private func applyLayoutChange() {
        actions.enqueue { [weak self] in
            await self?.runtime()?.applySettings()
            self?.context.resultsChanged()
        }
    }
}
