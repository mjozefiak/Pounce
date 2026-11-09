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
    /// The kinds the user can choose: Auto-tile, Zones and Free (Zones since phase 3).
    static let selectableKinds: [LayoutKind] = [.tiling, .zones, .free]

    static func kindName(_ kind: LayoutKind) -> String {
        switch kind {
        case .tiling: String(localized: "Auto-tile", comment: "Window Management layout kind: windows tile the screen")
        case .zones: String(localized: "Zones", comment: "Window Management layout kind: windows snap into zones")
        case .free: String(localized: "Free", comment: "Window Management layout kind: windows are left where they are")
        }
    }

    static func orientationName(_ orientation: TilingOrientation) -> String {
        switch orientation {
        case .horizontal:
            String(
                localized: "Side by side", comment: "Window Management: the first split of a workspace is horizontal")
        case .vertical:
            String(localized: "Stacked", comment: "Window Management: the first split of a workspace is vertical")
        }
    }

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

    /// "6 layouts · Zones on 2 workspaces": the line under *Layouts…* in Basics.
    var layoutsSummary: String {
        let layouts = String(
            localized: "\(StockLayouts.all.count + libraryLayouts.count) layouts",
            comment: "Settings: how many zone layouts exist")
        let config = layoutConfig
        let zones = WorkspaceID.all(count: workspaceCount).filter { config.resolved(for: $0).kind == .zones }.count
        let used =
            zones == 0
            ? String(localized: "No workspace uses Zones", comment: "Settings: no workspace is set to Zones")
            : String(localized: "Zones on \(zones) workspaces", comment: "Settings: how many workspaces use Zones")
        return "\(layouts) · \(used)"
    }

    func setInnerGap(_ points: Int) {
        settings.setInnerGap(points)
        innerGap = settings.innerGap
        applyLayoutChange()
    }

    func setOuterGap(_ points: Int) {
        settings.setOuterGap(points)
        outerGap = settings.outerGap
        applyLayoutChange()
    }

    // MARK: Summary

    /// The effective configuration of every workspace, so what the engine uses is always readable.
    var workspaceSummaries: [WorkspaceSummaryLine] {
        let config = layoutConfig
        return WorkspaceID.all(count: workspaceCount).map { workspace in
            let resolved = config.resolved(for: workspace)
            var parts = [Self.kindName(resolved.kind)]
            if resolved.kind == .tiling {
                let inner = Int(resolved.gaps.inner)
                let outer = Int(resolved.gaps.outer)
                parts.append(String(localized: "Gaps \(inner) / \(outer)", comment: "Window Management summary: gaps"))
                parts.append(Self.orientationName(resolved.rootOrientation))
            }
            return WorkspaceSummaryLine(
                workspace: workspace, detail: parts.joined(separator: " · "),
                isCustom: !(overrides.byWorkspace[workspace]?.isEmpty ?? true))
        }
    }

    /// The defaults and the overrides as the engine receives them.
    var layoutConfig: LayoutConfig {
        LayoutConfig(
            defaultKind: defaultKind, innerGap: innerGap, outerGap: outerGap, rootOrientation: .horizontal,
            overrides: overrides.byWorkspace)
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

    func setOverrideKind(_ kind: LayoutKind?, for workspace: WorkspaceID) {
        update(workspace) { $0.kind = kind }
    }

    func setOverrideInnerGap(_ points: Int?, for workspace: WorkspaceID) {
        update(workspace) { $0.innerGap = points.map(WindowsSettings.clampGap) }
    }

    func setOverrideOuterGap(_ points: Int?, for workspace: WorkspaceID) {
        update(workspace) { $0.outerGap = points.map(WindowsSettings.clampGap) }
    }

    func setOverrideOrientation(_ orientation: TilingOrientation?, for workspace: WorkspaceID) {
        update(workspace) { $0.rootOrientation = orientation }
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
        Task { [weak self] in
            await self?.runtime()?.applySettings()
            self?.context.resultsChanged()
        }
    }
}
