import Foundation
import LintelKit

/// The command ids of window management (spec: API Contracts) and their default shortcuts (Q10: the AeroSpace
/// set). Ids never change once shipped; the commands of a layout kind are declared by its strategy
/// (`LayoutStrategy.commands`) and named here so one file lists every id.
enum WindowsCommandID {
    static let prefix = "windows."
    static func workspace(_ number: Int) -> String { "windows.workspace.\(number)" }
    static func moveToWorkspace(_ number: Int) -> String { "windows.moveToWorkspace.\(number)" }
    static let next = "windows.workspace.next"
    static let previous = "windows.workspace.previous"
    static let back = "windows.workspace.back"
    static let restoreAll = "windows.restoreAllWindows"
    static func focus(_ direction: LayoutDirection) -> String { "windows.focus.\(direction.rawValue)" }
    static func move(_ direction: LayoutDirection) -> String { "windows.move.\(direction.rawValue)" }
    static func join(_ direction: LayoutDirection) -> String { "windows.join.\(direction.rawValue)" }
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

    /// The ids the plugin itself owns: a strategy's command may not take one of them (`LayoutRegistry.commandSpecs`
    /// leaves such a command out).
    static let reserved: Set<String> = {
        var ids: Set<String> = [next, previous, back, restoreAll, toggleFloating, toggleLayout, nextLayout]
        for number in 1...WindowsSettings.maximumWorkspaces {
            ids.insert(workspace(number))
            ids.insert(moveToWorkspace(number))
        }
        for number in 1...LayoutRules.slotCount { ids.insert(layoutSlot(number)) }
        for direction in LayoutDirection.allCases {
            ids.insert(focus(direction))
            ids.insert(move(direction))
        }
        return ids
    }()
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

    /// The commands of the family with the key each is bound to: the shared families are fixed, the strategies'
    /// commands that name a family join it (Auto-tile's resize is the one today).
    func bindings(in registry: LayoutRegistry) -> [(id: String, key: String)] {
        let fixed: [(id: String, key: String)]
        switch self {
        case .goToWorkspace:
            fixed = (1...WindowsSettings.maximumWorkspaces).map { (WindowsCommandID.workspace($0), String($0)) }
        case .moveToWorkspace:
            fixed = (1...WindowsSettings.maximumWorkspaces).map { (WindowsCommandID.moveToWorkspace($0), String($0)) }
        case .focus: fixed = Self.arrows.map { (WindowsCommandID.focus($0.direction), $0.key) }
        case .moveWindow: fixed = Self.arrows.map { (WindowsCommandID.move($0.direction), $0.key) }
        case .resize: fixed = []
        }
        let contributed = registry.commandSpecs.compactMap { spec -> (id: String, key: String)? in
            guard spec.family == self, let key = spec.key else { return nil }
            return (spec.id, key)
        }
        return fixed + contributed
    }

    /// The families that have a command in `registry` (the pane shows a modifier row for each).
    static func active(in registry: LayoutRegistry) -> [ShortcutFamily] {
        allCases.filter { !$0.bindings(in: registry).isEmpty }
    }

    /// The vi keys of the AeroSpace set.
    static let arrows: [(direction: LayoutDirection, key: String)] = [
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
    func shortcuts(in registry: LayoutRegistry, modifiers: KeyShortcut.Modifiers? = nil) -> [KeyShortcut] {
        bindings(in: registry).map { KeyShortcut(key: $0.key, modifiers: modifiers ?? defaultModifiers) }
    }

    func defaultShortcut(for id: String, in registry: LayoutRegistry) -> KeyShortcut? {
        bindings(in: registry).first { $0.id == id }.map { KeyShortcut(key: $0.key, modifiers: defaultModifiers) }
    }
}

extension WindowsPlugin {
    /// Every default shortcut that is bound now (for the layout check and `DefaultShortcutTests`).
    static var defaultShortcuts: [KeyShortcut] { defaultShortcuts(in: .standard) }

    static func defaultShortcuts(in registry: LayoutRegistry) -> [KeyShortcut] {
        ShortcutFamily.allCases.flatMap { $0.shortcuts(in: registry) } + [
            KeyShortcut(key: "\t", modifiers: [.option]), toggleLayoutShortcut,
        ]
    }

    /// ⌥/ cycles the layout kind of the current workspace (Q10).
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
        commands.append(contentsOf: layoutCommands)
        commands.append(
            PluginCommand(
                id: WindowsCommandID.restoreAll,
                title: LocalizedStringResource(
                    "Restore All Windows", comment: "Menu item and command: puts every parked window back"),
                symbolName: "arrow.counterclockwise",
                run: { [weak self] in await self?.restoreAllWindows() }))
        return commands
    }

    /// The layout commands: the shared verbs every arranged kind may answer (focus and move to the neighbour,
    /// toggle floating), then whatever the registered strategies contribute (`LayoutStrategy.commands`: Auto-tile's
    /// join and resize, Zones' *Move Window to Zone N*), then the layout-library commands when any strategy uses
    /// the library (*Use Layout Slot N*, *Next Zone Layout*), then *Toggle Layout*. All are `showsInMenu: false`;
    /// the focus, move and resize families have the AeroSpace defaults (Q10), the rest are unbound.
    private var layoutCommands: [PluginCommand] {
        var commands: [PluginCommand] = []
        func add(
            _ id: String, _ title: LocalizedStringResource, symbol: String, shortcut: KeyShortcut?,
            command: EngineCommand, purpose: AccessibilityPurpose = .moving
        ) {
            commands.append(
                PluginCommand(
                    id: id, title: title, symbolName: symbol, defaultShortcut: shortcut, showsInMenu: false,
                    run: { [weak self] in await self?.perform(command, purpose: purpose) }))
        }
        for direction in LayoutDirection.allCases {
            add(
                WindowsCommandID.focus(direction), Self.focusTitle(direction), symbol: "scope",
                shortcut: ShortcutFamily.focus.defaultShortcut(for: WindowsCommandID.focus(direction), in: registry),
                command: .focusDirection(direction))
        }
        for direction in LayoutDirection.allCases {
            add(
                WindowsCommandID.move(direction), Self.moveTitle(direction),
                symbol: "arrow.up.and.down.and.arrow.left.and.right",
                shortcut: ShortcutFamily.moveWindow.defaultShortcut(
                    for: WindowsCommandID.move(direction), in: registry),
                command: .moveDirection(direction))
        }
        add(
            WindowsCommandID.toggleFloating,
            LocalizedStringResource(
                "Toggle Floating", comment: "Command: takes the focused window out of tiling or back in"),
            symbol: "rectangle.on.rectangle", shortcut: nil, command: .toggleFloating)
        for spec in registry.commandSpecs {
            add(
                spec.id, spec.title, symbol: spec.symbolName, shortcut: spec.defaultShortcut, command: spec.command,
                purpose: spec.purpose)
        }
        if !registry.libraryKinds.isEmpty {
            for number in 1...LayoutRules.slotCount {
                commands.append(
                    PluginCommand(
                        id: WindowsCommandID.layoutSlot(number),
                        title: LocalizedStringResource(
                            "Use Layout Slot \(number)",
                            comment: "Command: gives the current workspace the layout bound to a numbered slot"),
                        symbolName: "square.grid.3x1.below.line.grid.1x2", showsInMenu: false,
                        run: { [weak self] in await self?.runtime?.layoutCommands.applyLayoutSlot(number) }))
            }
            commands.append(
                PluginCommand(
                    id: WindowsCommandID.nextLayout,
                    title: LocalizedStringResource(
                        "Next Zone Layout",
                        comment: "Command: switches the current workspace to the next zone layout"),
                    symbolName: "square.grid.2x2.fill", showsInMenu: false,
                    run: { [weak self] in await self?.runtime?.layoutCommands.nextLayout() }))
        }
        commands.append(
            PluginCommand(
                id: WindowsCommandID.toggleLayout,
                title: LocalizedStringResource(
                    "Toggle Layout", comment: "Command: cycles the layout kind of the current workspace"),
                symbolName: "square.grid.2x2", defaultShortcut: Self.toggleLayoutShortcut, showsInMenu: false,
                run: { [weak self] in await self?.toggleLayout() }))
        return commands
    }

    private static func focusTitle(_ direction: LayoutDirection) -> LocalizedStringResource {
        switch direction {
        case .left: LocalizedStringResource("Focus Left", comment: "Command: moves the focus to the tile on the left")
        case .right:
            LocalizedStringResource("Focus Right", comment: "Command: moves the focus to the tile on the right")
        case .up: LocalizedStringResource("Focus Up", comment: "Command: moves the focus to the tile above")
        case .down: LocalizedStringResource("Focus Down", comment: "Command: moves the focus to the tile below")
        }
    }

    private static func moveTitle(_ direction: LayoutDirection) -> LocalizedStringResource {
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

    /// Runs an engine command, but only while the plugin is on and Accessibility is trusted.
    func perform(_ command: EngineCommand, purpose: AccessibilityPurpose) async {
        await runtime?.run(command, purpose: purpose)
    }

    func toggleLayout() async {
        await runtime?.layoutCommands.toggleLayout()
    }

    public var searchSources: [any SearchSource] {
        [WindowSearchSource(switcher: runtime ?? InactiveSwitcher())]
    }
}
