import Foundation
import LintelKit

/// The commands of window management (spec: API Contracts) that exist in this phase, and their default
/// shortcuts (Q10: the AeroSpace set, a default registered in the phase that implements its command).
enum WindowsCommandID {
    static let prefix = "windows."
    static func workspace(_ number: Int) -> String { "windows.workspace.\(number)" }
    static func moveToWorkspace(_ number: Int) -> String { "windows.moveToWorkspace.\(number)" }
    static let next = "windows.workspace.next"
    static let previous = "windows.workspace.previous"
    static let back = "windows.workspace.back"
    static let restoreAll = "windows.restoreAllWindows"
}

/// A family of numbered commands that share one modifier row in Settings (the digits stay fixed).
enum ShortcutFamily: String, CaseIterable {
    case goToWorkspace
    case moveToWorkspace

    /// The default modifiers (Q10).
    var defaultModifiers: KeyShortcut.Modifiers {
        switch self {
        case .goToWorkspace: [.option]
        case .moveToWorkspace: [.option, .shift]
        }
    }

    func commandID(_ number: Int) -> String {
        switch self {
        case .goToWorkspace: WindowsCommandID.workspace(number)
        case .moveToWorkspace: WindowsCommandID.moveToWorkspace(number)
        }
    }

    /// The default shortcuts of the family, workspaces 1 through 9.
    func shortcuts(modifiers: KeyShortcut.Modifiers? = nil) -> [KeyShortcut] {
        (1...WindowsSettings.maximumWorkspaces).map {
            KeyShortcut(key: String($0), modifiers: modifiers ?? defaultModifiers)
        }
    }
}

extension WindowsPlugin {
    /// Every default shortcut that is bound now (for the layout check and `DefaultShortcutTests`).
    static var defaultShortcuts: [KeyShortcut] {
        ShortcutFamily.allCases.flatMap { $0.shortcuts() } + [KeyShortcut(key: "\t", modifiers: [.option])]
    }

    public var commands: [PluginCommand] {
        var commands: [PluginCommand] = []
        for number in 1...WindowsSettings.maximumWorkspaces {
            guard let workspace = WorkspaceID(number) else { continue }
            commands.append(
                PluginCommand(
                    id: WindowsCommandID.workspace(number),
                    title: LocalizedStringResource(
                        "Go to Workspace \(number)", comment: "Command: switches to a numbered workspace"),
                    symbolName: "rectangle.3.group",
                    defaultShortcut: KeyShortcut(
                        key: String(number), modifiers: ShortcutFamily.goToWorkspace.defaultModifiers),
                    showsInMenu: false,
                    run: { [weak self] in await self?.perform(.showWorkspace(workspace), purpose: .switching) }))
        }
        for number in 1...WindowsSettings.maximumWorkspaces {
            guard let workspace = WorkspaceID(number) else { continue }
            commands.append(
                PluginCommand(
                    id: WindowsCommandID.moveToWorkspace(number),
                    title: LocalizedStringResource(
                        "Move Window to Workspace \(number)",
                        comment: "Command: moves the focused window to a numbered workspace"),
                    symbolName: "arrow.right.square",
                    defaultShortcut: KeyShortcut(
                        key: String(number), modifiers: ShortcutFamily.moveToWorkspace.defaultModifiers),
                    showsInMenu: false,
                    run: { [weak self] in
                        await self?.perform(.moveFocusedWindow(to: workspace), purpose: .moving)
                    }))
        }
        commands.append(
            PluginCommand(
                id: WindowsCommandID.next,
                title: LocalizedStringResource("Next Workspace", comment: "Command: switches to the next workspace"),
                symbolName: "chevron.right", showsInMenu: false,
                run: { [weak self] in await self?.perform(.nextWorkspace, purpose: .switching) }))
        commands.append(
            PluginCommand(
                id: WindowsCommandID.previous,
                title: LocalizedStringResource(
                    "Previous Workspace", comment: "Command: switches to the previous workspace"),
                symbolName: "chevron.left", showsInMenu: false,
                run: { [weak self] in await self?.perform(.previousWorkspace, purpose: .switching) }))
        commands.append(
            PluginCommand(
                id: WindowsCommandID.back,
                title: LocalizedStringResource(
                    "Back to the Last Workspace", comment: "Command: goes back to the workspace used before"),
                symbolName: "arrow.uturn.backward",
                defaultShortcut: KeyShortcut(key: "\t", modifiers: [.option]), showsInMenu: false,
                run: { [weak self] in await self?.perform(.backAndForth, purpose: .switching) }))
        commands.append(
            PluginCommand(
                id: WindowsCommandID.restoreAll,
                title: LocalizedStringResource(
                    "Restore All Windows", comment: "Menu item and command: puts every parked window back"),
                symbolName: "arrow.counterclockwise",
                run: { [weak self] in await self?.restoreAllWindows() }))
        return commands
    }

    /// Runs an engine command, but only while the plugin is on and Accessibility is trusted.
    func perform(_ command: EngineCommand, purpose: AccessibilityPurpose) async {
        await runtime?.run(command, purpose: purpose)
    }

    public var searchSources: [any SearchSource] {
        [WindowSearchSource(switcher: runtime ?? InactiveSwitcher())]
    }
}
