import Foundation
import LintelKit
import Observation

/// The state behind the Configure window (window management v2, Phase 2): the shortcut list with groups, search,
/// conflicts and the characters-on-the-keyboard flag; the workspace table (names, kind, gaps, direction) and the
/// global gaps and layout values. It reads and writes through the pane's model (`WindowsSettingsModel`), so the
/// pane, the window and the engine can never disagree, and holds nothing of its own that is stored.
@MainActor @Observable
final class WindowsConfigureModel {
    enum Section: String, CaseIterable, Identifiable {
        case shortcuts
        case workspaces
        case gapsAndLayout
        case rules

        var id: String { rawValue }
    }

    enum Group: Int, CaseIterable, Identifiable {
        case workspaces, focus, move, layout, resize, display, other

        var id: Int { rawValue }
    }

    struct ShortcutRow: Identifiable, Equatable {
        var id: String
        var title: String
        var group: Group
        var shortcut: KeyShortcut?
        var defaultShortcut: KeyShortcut?
        /// The shortcut types a character on the active keyboard layout.
        var typesCharacter: Bool
        /// The title of another command that has the same shortcut.
        var conflict: String?

        var isDefault: Bool { shortcut == defaultShortcut }
    }

    var section: Section = .shortcuts
    var query = ""
    private(set) var rows: [ShortcutRow] = []
    private(set) var names: WorkspaceNames

    @ObservationIgnored let pane: WindowsSettingsModel
    @ObservationIgnored private let commands: () -> [PluginCommand]

    init(pane: WindowsSettingsModel, commands: @escaping () -> [PluginCommand]) {
        self.pane = pane
        self.commands = commands
        names = pane.settings.workspaceNames
        refresh()
    }

    // MARK: Shortcuts

    /// The commands that get a row of their own: the numbered ones share one *Modifiers* row per family.
    static func hasOwnRow(_ id: String) -> Bool {
        for number in 1...WindowsSettings.maximumWorkspaces
        where id == WindowsCommandID.workspace(number) || id == WindowsCommandID.moveToWorkspace(number) {
            return false
        }
        return true
    }

    static func group(of id: String) -> Group {
        if id == WindowsCommandID.moveToNextDisplay { return .display }
        if id.hasPrefix("windows.workspace.") || id.hasPrefix("windows.moveToWorkspace.") { return .workspaces }
        if id.hasPrefix("windows.focus.") { return .focus }
        if id.hasPrefix("windows.move.") || id.hasPrefix("windows.join.") { return .move }
        if id.hasPrefix("windows.resize.") { return .resize }
        if id.hasPrefix("windows.layout.") || id.hasPrefix("windows.zones.") || id == WindowsCommandID.toggleLayout
            || id == WindowsCommandID.toggleOrientation || id == WindowsCommandID.balance
        {
            return .layout
        }
        return .other
    }

    /// Reads the shortcuts, the conflicts and the keyboard check again (the window appeared, a recorder changed
    /// something, the keyboard layout changed).
    func refresh() {
        pane.refreshSafety()
        let flagged = Set(pane.flagged.map(\.id))
        var built: [ShortcutRow] = commands().filter { Self.hasOwnRow($0.id) }.map { command in
            ShortcutRow(
                id: command.id, title: String(localized: command.title), group: Self.group(of: command.id),
                shortcut: pane.context.commandShortcut(command.id), defaultShortcut: command.defaultShortcut,
                typesCharacter: flagged.contains(command.id), conflict: nil)
        }
        var owners: [KeyShortcut: [Int]] = [:]
        for (index, row) in built.enumerated() {
            if let shortcut = row.shortcut { owners[shortcut, default: []].append(index) }
        }
        for indexes in owners.values where indexes.count > 1 {
            for index in indexes {
                built[index].conflict = indexes.first { $0 != index }.map { built[$0].title }
            }
        }
        rows = built
        names = pane.settings.workspaceNames
    }

    /// The rows of a group that match the search (every word in the title, ignoring case and diacritics).
    func rows(in group: Group) -> [ShortcutRow] {
        let words = query.split(separator: " ").map(String.init)
        return rows.filter { row in
            row.group == group
                && words.allSatisfy { row.title.localizedStandardContains($0) }
        }
    }

    /// The groups that have a row for the search, in order; the numbered families' *Modifiers* rows belong to
    /// Workspaces and Focus/Move and are shown with the unfiltered list.
    var visibleGroups: [Group] { Group.allCases.filter { !rows(in: $0).isEmpty } }

    /// The numbered families with a *Modifiers* row.
    var modifierFamilies: [ShortcutFamily] { [.goToWorkspace, .moveToWorkspace] }

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var flaggedCount: Int { rows.filter(\.typesCharacter).count }

    /// Back to the command's own default; another command that holds it loses it first (never two owners).
    func reset(_ id: String) {
        guard let command = commands().first(where: { $0.id == id }) else { return }
        if let target = command.defaultShortcut,
            let other = commands().first(where: { $0.id != id && pane.context.commandShortcut($0.id) == target })
        {
            pane.context.setCommandShortcut(other.id, nil)
        }
        pane.context.setCommandShortcut(id, command.defaultShortcut)
        refresh()
    }

    /// *Reset all to defaults*: every shortcut is cleared first, then the defaults are set, so no key is ever held
    /// twice in between.
    func resetAll() {
        let all = commands()
        for command in all { pane.context.setCommandShortcut(command.id, nil) }
        for command in all where command.defaultShortcut != nil {
            pane.context.setCommandShortcut(command.id, command.defaultShortcut)
        }
        refresh()
    }

    /// *Replace*: the other command gives the shortcut up.
    func replaceConflict(of id: String) {
        guard let row = rows.first(where: { $0.id == id }), let shortcut = row.shortcut else { return }
        for other in rows where other.id != id && other.shortcut == shortcut {
            pane.context.setCommandShortcut(other.id, nil)
        }
        refresh()
    }

    /// *Use ⌃⌥* for one flagged command.
    func useControlOption(for id: String) {
        guard let row = rows.first(where: { $0.id == id }), let shortcut = row.shortcut else { return }
        pane.context.setCommandShortcut(id, ShortcutSafety.controlOption(for: [shortcut])[0])
        refresh()
    }

    var shortcutCount: Int { Self.shortcutCount(pane: pane, commands: commands()) }

    static func shortcutCount(pane: WindowsSettingsModel, commands: [PluginCommand]) -> Int {
        commands.filter { pane.context.commandShortcut($0.id) != nil }.count
    }

    // MARK: Workspaces

    var workspaces: [WorkspaceID] { WorkspaceID.all(count: pane.workspaceCount) }

    func name(of workspace: WorkspaceID) -> String { names.name(of: workspace) ?? "" }

    /// Stores a name (made valid first; an empty one clears it). Nothing is written over a newer version's value.
    func setName(_ text: String, for workspace: WorkspaceID) {
        var next = names
        guard !next.isReadOnly else { return }
        next.set(text, for: workspace)
        guard pane.settings.setWorkspaceNames(next) else { return }
        names = next
        pane.context.resultsChanged()
        pane.actions.enqueue { [pane] in await pane.runtime()?.applySettings() }
    }

    var namesLocked: Bool { names.isReadOnly }

    /// The layout kind choice of a workspace, or `useDefaultChoice`.
    func kindChoice(of workspace: WorkspaceID) -> String {
        pane.override(for: workspace).kind?.rawValue ?? WindowsSettingsModel.useDefaultChoice
    }

    /// "Default · 10 pt" or "12 pt": the effective gaps of a workspace and whether they are its own. Only the kinds
    /// that have gap options of their own show them.
    func gapsSummary(of workspace: WorkspaceID) -> String {
        let resolved = pane.layoutConfig.resolved(for: workspace)
        let isOwn = [TilingStrategy.innerGapID, TilingStrategy.outerGapID].contains {
            pane.override(for: workspace).options[$0] != nil
        }
        let inner = resolved.tilingGaps.inner
        let outer = resolved.tilingGaps.outer
        let points = inner == outer ? "\(Int(inner)) pt" : "\(Int(inner)) / \(Int(outer)) pt"
        return isOwn
            ? points : String(localized: "Default · \(points)", comment: "Configure: the gaps follow the global value")
    }

    /// Sets (or with `nil` clears) both gaps of a workspace together.
    func setGaps(_ points: Int?, for workspace: WorkspaceID) {
        for id in [TilingStrategy.innerGapID, TilingStrategy.outerGapID] {
            guard let option = pane.registry.option(id: id) else { continue }
            pane.setOverrideOption(option, to: points.map { .int($0) }, for: workspace)
        }
    }

    func gapsValue(of workspace: WorkspaceID) -> Int? {
        if case .int(let value)? = pane.override(for: workspace).options[TilingStrategy.innerGapID] { return value }
        return nil
    }

    /// The direction option of the kind the workspace uses (Auto-tile's first split, Accordion's direction), if any.
    func orientationOption(of workspace: WorkspaceID) -> LayoutOption? {
        let kind = pane.layoutConfig.resolved(for: workspace).kind
        let id =
            kind == .accordion
            ? AccordionStrategy.orientationID : kind == .tiling ? TilingStrategy.rootOrientationID : nil
        return id.flatMap { pane.registry.option(id: $0) }
    }

    func orientationChoice(of workspace: WorkspaceID) -> String {
        guard let option = orientationOption(of: workspace) else { return WindowsSettingsModel.useDefaultChoice }
        if case .string(let value)? = pane.override(for: workspace).options[option.id] { return value }
        return WindowsSettingsModel.useDefaultChoice
    }

    func setOrientation(_ choice: String, for workspace: WorkspaceID) {
        guard let option = orientationOption(of: workspace) else { return }
        pane.setOverrideOption(
            option, to: choice == WindowsSettingsModel.useDefaultChoice ? nil : .string(choice), for: workspace)
    }

    // MARK: Gaps and layout

    /// The global options the window edits: the gaps, the accordion padding and the resize step.
    var globalOptions: [LayoutOption] { pane.globalOptionRows }

    var summary: String { Self.summary(pane: pane, commands: commands()) }

    /// The number of rules the Rules section lists: the floating apps and the workspace rules.
    static func ruleCount(pane: WindowsSettingsModel) -> Int {
        Set(pane.floatingApps).union(pane.settings.appRules.entries.map(\.bundleID)).count
    }

    /// "9 workspaces · 12 shortcuts": the line under the *Configure…* row, read without building the window's model.
    static func summary(pane: WindowsSettingsModel, commands: [PluginCommand]) -> String {
        String(
            localized:
                "\(pane.workspaceCount) workspaces · \(shortcutCount(pane: pane, commands: commands)) shortcuts · \(ruleCount(pane: pane)) rules",
            comment: "Settings: the line under Configure (how many workspaces and shortcuts)")
    }
}
