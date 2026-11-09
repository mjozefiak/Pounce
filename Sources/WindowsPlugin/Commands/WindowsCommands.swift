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
    static func focus(_ direction: TilingDirection) -> String { "windows.focus.\(direction.rawValue)" }
    static func move(_ direction: TilingDirection) -> String { "windows.move.\(direction.rawValue)" }
    static func join(_ direction: TilingDirection) -> String { "windows.join.\(direction.rawValue)" }
    static let grow = "windows.resize.grow"
    static let shrink = "windows.resize.shrink"
    static let toggleOrientation = "windows.toggleOrientation"
    static let toggleFloating = "windows.toggleFloating"
    static let balance = "windows.balance"
    static let toggleLayout = "windows.toggleLayout"
    static func zone(_ number: Int) -> String { "windows.zones.zone.\(number)" }
    /// The nine layout slots: stable commands, each bound to a layout in the pane (spec: API Contracts).
    static func layoutSlot(_ number: Int) -> String { "windows.zones.layout.\(number)" }
    static let nextLayout = "windows.zones.nextLayout"
}

/// A family of commands that share one modifier row in Settings (the keys stay fixed).
enum ShortcutFamily: String, CaseIterable {
    case goToWorkspace
    case moveToWorkspace
    case focus
    case moveWindow
    case resize

    /// The default modifiers (Q10).
    var defaultModifiers: KeyShortcut.Modifiers {
        switch self {
        case .goToWorkspace, .focus, .resize: [.option]
        case .moveToWorkspace, .moveWindow: [.option, .shift]
        }
    }

    /// The family that is bound to the same keys: the two must use different modifiers.
    var partner: ShortcutFamily? {
        switch self {
        case .goToWorkspace: .moveToWorkspace
        case .moveToWorkspace: .goToWorkspace
        case .focus: .moveWindow
        case .moveWindow: .focus
        case .resize: nil
        }
    }

    /// The commands of the family with the key each is bound to.
    var bindings: [(id: String, key: String)] {
        switch self {
        case .goToWorkspace:
            (1...WindowsSettings.maximumWorkspaces).map { (WindowsCommandID.workspace($0), String($0)) }
        case .moveToWorkspace:
            (1...WindowsSettings.maximumWorkspaces).map { (WindowsCommandID.moveToWorkspace($0), String($0)) }
        case .focus: Self.arrows.map { (WindowsCommandID.focus($0.direction), $0.key) }
        case .moveWindow: Self.arrows.map { (WindowsCommandID.move($0.direction), $0.key) }
        case .resize: [(WindowsCommandID.grow, "="), (WindowsCommandID.shrink, "-")]
        }
    }

    /// The vi keys of the AeroSpace set.
    static let arrows: [(direction: TilingDirection, key: String)] = [
        (.left, "h"), (.down, "j"), (.up, "k"), (.right, "l"),
    ]

    /// The keys as the pane shows them next to the modifiers.
    var keysLabel: String {
        switch self {
        case .goToWorkspace, .moveToWorkspace: "1–9"
        case .focus, .moveWindow: "H J K L"
        case .resize: "- ="
        }
    }

    /// The default shortcuts of the family.
    func shortcuts(modifiers: KeyShortcut.Modifiers? = nil) -> [KeyShortcut] {
        bindings.map { KeyShortcut(key: $0.key, modifiers: modifiers ?? defaultModifiers) }
    }

    func defaultShortcut(for id: String) -> KeyShortcut? {
        bindings.first { $0.id == id }.map { KeyShortcut(key: $0.key, modifiers: defaultModifiers) }
    }
}

extension WindowsPlugin {
    /// Every default shortcut that is bound now (for the layout check and `DefaultShortcutTests`).
    static var defaultShortcuts: [KeyShortcut] {
        ShortcutFamily.allCases.flatMap { $0.shortcuts() } + [
            KeyShortcut(key: "\t", modifiers: [.option]), toggleLayoutShortcut,
        ]
    }

    /// ⌥/ cycles the layout kind of the current workspace (Q10, step 3.4).
    static let toggleLayoutShortcut = KeyShortcut(key: "/", modifiers: [.option])

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
        commands.append(contentsOf: tilingCommands)
        commands.append(
            PluginCommand(
                id: WindowsCommandID.restoreAll,
                title: LocalizedStringResource(
                    "Restore All Windows", comment: "Menu item and command: puts every parked window back"),
                symbolName: "arrow.counterclockwise",
                run: { [weak self] in await self?.restoreAllWindows() }))
        return commands
    }

    /// The Auto-tile commands (spec: API Contracts). All are `showsInMenu: false`; the focus, move and resize
    /// families have the AeroSpace defaults (Q10), the rest are unbound. `toggleLayout` is ⌥/ since phase 3,
    /// when Zones exist to cycle through.
    private var tilingCommands: [PluginCommand] {
        var commands: [PluginCommand] = []
        func add(
            _ id: String, _ title: LocalizedStringResource, symbol: String, command: EngineCommand
        ) {
            let family = ShortcutFamily.allCases.first { $0.bindings.contains { $0.id == id } }
            commands.append(
                PluginCommand(
                    id: id, title: title, symbolName: symbol, defaultShortcut: family?.defaultShortcut(for: id),
                    showsInMenu: false,
                    run: { [weak self] in await self?.perform(command, purpose: .moving) }))
        }
        for direction in TilingDirection.allCases {
            add(
                WindowsCommandID.focus(direction), Self.focusTitle(direction), symbol: "scope",
                command: .focusDirection(direction))
        }
        for direction in TilingDirection.allCases {
            add(
                WindowsCommandID.move(direction), Self.moveTitle(direction),
                symbol: "arrow.up.and.down.and.arrow.left.and.right",
                command: .moveInTree(direction))
        }
        add(
            WindowsCommandID.grow,
            LocalizedStringResource("Grow Window", comment: "Command: makes the focused tile larger"),
            symbol: "arrow.up.left.and.arrow.down.right", command: .resize(TilingTree.resizeStep))
        add(
            WindowsCommandID.shrink,
            LocalizedStringResource("Shrink Window", comment: "Command: makes the focused tile smaller"),
            symbol: "arrow.down.right.and.arrow.up.left", command: .resize(-TilingTree.resizeStep))
        for direction in TilingDirection.allCases {
            add(
                WindowsCommandID.join(direction), Self.joinTitle(direction), symbol: "rectangle.split.2x1",
                command: .join(direction))
        }
        add(
            WindowsCommandID.toggleOrientation,
            LocalizedStringResource(
                "Toggle Split Direction", comment: "Command: flips the container of the focused window"),
            symbol: "rectangle.split.2x1", command: .toggleOrientation)
        add(
            WindowsCommandID.toggleFloating,
            LocalizedStringResource(
                "Toggle Floating", comment: "Command: takes the focused window out of tiling or back in"),
            symbol: "rectangle.on.rectangle", command: .toggleFloating)
        add(
            WindowsCommandID.balance,
            LocalizedStringResource("Balance Windows", comment: "Command: gives every tile the same size"),
            symbol: "equal.square", command: .balance)
        for number in 1...WindowsSettings.maximumWorkspaces {
            commands.append(
                PluginCommand(
                    id: WindowsCommandID.zone(number),
                    title: LocalizedStringResource(
                        "Move Window to Zone \(number)", comment: "Command: moves the focused window to a numbered zone"
                    ),
                    symbolName: "rectangle.split.3x1", showsInMenu: false,
                    run: { [weak self] in await self?.perform(.moveToZone(number), purpose: .moving) }))
        }
        for number in 1...LayoutRules.slotCount {
            commands.append(
                PluginCommand(
                    id: WindowsCommandID.layoutSlot(number),
                    title: LocalizedStringResource(
                        "Use Layout Slot \(number)",
                        comment: "Command: gives the current workspace the layout bound to a numbered slot"),
                    symbolName: "square.grid.3x1.below.line.grid.1x2", showsInMenu: false,
                    run: { [weak self] in await self?.runtime?.applyLayoutSlot(number) }))
        }
        commands.append(
            PluginCommand(
                id: WindowsCommandID.nextLayout,
                title: LocalizedStringResource(
                    "Next Zone Layout", comment: "Command: switches the current workspace to the next zone layout"),
                symbolName: "square.grid.2x2.fill", showsInMenu: false,
                run: { [weak self] in await self?.runtime?.nextLayout() }))
        commands.append(
            PluginCommand(
                id: WindowsCommandID.toggleLayout,
                title: LocalizedStringResource(
                    "Toggle Layout", comment: "Command: cycles the layout kind of the current workspace"),
                symbolName: "square.grid.2x2", defaultShortcut: Self.toggleLayoutShortcut, showsInMenu: false,
                run: { [weak self] in await self?.toggleLayout() }))
        return commands
    }

    private static func focusTitle(_ direction: TilingDirection) -> LocalizedStringResource {
        switch direction {
        case .left: LocalizedStringResource("Focus Left", comment: "Command: moves the focus to the tile on the left")
        case .right:
            LocalizedStringResource("Focus Right", comment: "Command: moves the focus to the tile on the right")
        case .up: LocalizedStringResource("Focus Up", comment: "Command: moves the focus to the tile above")
        case .down: LocalizedStringResource("Focus Down", comment: "Command: moves the focus to the tile below")
        }
    }

    private static func moveTitle(_ direction: TilingDirection) -> LocalizedStringResource {
        switch direction {
        case .left:
            LocalizedStringResource("Move Window Left", comment: "Command: moves the focused window in the tree")
        case .right:
            LocalizedStringResource("Move Window Right", comment: "Command: moves the focused window in the tree")
        case .up: LocalizedStringResource("Move Window Up", comment: "Command: moves the focused window in the tree")
        case .down:
            LocalizedStringResource("Move Window Down", comment: "Command: moves the focused window in the tree")
        }
    }

    private static func joinTitle(_ direction: TilingDirection) -> LocalizedStringResource {
        switch direction {
        case .left:
            LocalizedStringResource(
                "Join with Left Window", comment: "Command: groups the focused window with its neighbour")
        case .right:
            LocalizedStringResource(
                "Join with Right Window", comment: "Command: groups the focused window with its neighbour")
        case .up:
            LocalizedStringResource(
                "Join with Window Above", comment: "Command: groups the focused window with its neighbour")
        case .down:
            LocalizedStringResource(
                "Join with Window Below", comment: "Command: groups the focused window with its neighbour")
        }
    }

    /// Runs an engine command, but only while the plugin is on and Accessibility is trusted.
    func perform(_ command: EngineCommand, purpose: AccessibilityPurpose) async {
        await runtime?.run(command, purpose: purpose)
    }

    func toggleLayout() async {
        await runtime?.toggleLayout()
    }

    public var searchSources: [any SearchSource] {
        [WindowSearchSource(switcher: runtime ?? InactiveSwitcher())]
    }
}
